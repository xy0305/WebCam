import Foundation
import WhisperKit

/// Owns the loaded WhisperKit pipeline. Actor isolation keeps all inference off the main thread.
actor LiveCaptionWhisperEngine {
    static let shared = LiveCaptionWhisperEngine()

    private var kit: WhisperKit?
    private var folder: URL?

    func load(folder: URL) async throws {
        if kit != nil, self.folder == folder { return }
        kit = nil
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: LiveCaptionModelStore.whisperBase,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
        self.folder = folder
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
        folder = nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit else { throw LiveCaptionEngineError.notReady }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            noSpeechThreshold: 0.6
        )
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}

/// Whisper (small.en / base.en) English ASR: ~4 s windows with 0.5 s overlap.
final class LiveCaptionWhisperRecognizer: LiveCaptionRecognizing, @unchecked Sendable {
    let chunkSamples = 64_000      // 4.0 s @ 16 kHz
    let overlapSamples = 8_000     // 0.5 s
    let displayName: String

    private init(model: LiveCaptionWhisperModel) {
        displayName = "Whisper \(model == .smallEn ? "small.en" : "base.en")"
    }

    /// Returns nil when the model is not downloaded / prepared yet (caller falls back to Apple Speech).
    static func makeIfReady(_ model: LiveCaptionWhisperModel) async -> LiveCaptionWhisperRecognizer? {
        guard let folder = LiveCaptionModelStore.readyWhisperFolder(model) else { return nil }
        do {
            try await LiveCaptionWhisperEngine.shared.load(folder: folder)
            return LiveCaptionWhisperRecognizer(model: model)
        } catch {
            return nil
        }
    }

    func prepare() async throws {}

    func transcribe(samples: [Float]) async throws -> String {
        guard !samples.isEmpty, !LiveCaptionAudio.isSilent(samples) else { return "" }
        let raw = try await LiveCaptionWhisperEngine.shared.transcribe(samples)
        return Self.clean(raw)
    }

    /// Drop Whisper non-speech tags and the classic music/silence hallucinations.
    static func clean(_ text: String) -> String {
        var s = text
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"♪+"#, #"<\|[^|]*\|>"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let hallucinations: Set<String> = [
            "thank you", "thanks for watching", "thank you for watching", "you", "bye", "music",
            "please subscribe", "subscribe", "thank you so much for watching",
        ]
        if lowered.isEmpty || hallucinations.contains(lowered) { return "" }
        return s
    }
}
