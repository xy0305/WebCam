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

/// Whisper (small.en / base.en) English ASR. Window size depends on「更快 / 更准」.
final class LiveCaptionWhisperRecognizer: LiveCaptionRecognizing, @unchecked Sendable {
    let chunkSamples: Int
    let overlapSamples: Int
    let displayName: String
    let minFlushSamples: Int
    let silenceTailSamples: Int

    private init(model: LiveCaptionWhisperModel, pace: LiveCaptionPaceMode) {
        displayName = "Whisper \(model == .smallEn ? "small.en" : "base.en")"
        switch (pace, model) {
        case (.fast, .baseEn):
            // Lowest lag; fragments are assembled upstream when possible.
            chunkSamples = 28_000   // 1.75 s
            overlapSamples = 3_200  // 0.20 s
            minFlushSamples = 14_000 // 0.875 s
            silenceTailSamples = Int(0.35 * LiveCaptionAudio.sampleRate)
        case (.fast, .smallEn):
            chunkSamples = 32_000   // 2.0 s
            overlapSamples = 3_200
            minFlushSamples = 16_000
            silenceTailSamples = Int(0.40 * LiveCaptionAudio.sampleRate)
        case (.accurate, .baseEn):
            // Prefer complete short utterances over ultra-short fragments.
            chunkSamples = 40_000   // 2.5 s
            overlapSamples = 4_800  // 0.30 s
            minFlushSamples = 20_000 // 1.25 s
            silenceTailSamples = Int(0.50 * LiveCaptionAudio.sampleRate)
        case (.accurate, .smallEn):
            chunkSamples = 48_000   // 3.0 s
            overlapSamples = 4_800
            minFlushSamples = 24_000 // 1.5 s
            silenceTailSamples = Int(0.55 * LiveCaptionAudio.sampleRate)
        }
    }

    /// Returns nil when the model is not downloaded / prepared yet (caller falls back to Apple Speech).
    static func makeIfReady(
        _ model: LiveCaptionWhisperModel,
        pace: LiveCaptionPaceMode = LiveCaptionPreference.pace
    ) async -> LiveCaptionWhisperRecognizer? {
        guard let folder = LiveCaptionModelStore.readyWhisperFolder(model) else { return nil }
        do {
            try await LiveCaptionWhisperEngine.shared.load(folder: folder)
            return LiveCaptionWhisperRecognizer(model: model, pace: pace)
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
