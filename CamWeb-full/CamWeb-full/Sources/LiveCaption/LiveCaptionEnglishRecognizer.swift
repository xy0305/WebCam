import AVFoundation
import Foundation
import Speech

#if os(iOS) || os(macOS)

enum LiveCaptionSpeechAuthorization: Sendable {
    case authorized, denied, restricted, notDetermined, unsupported
}

/// On-device English ASR for live captions (SpeechAnalyzer on newer OS, SFSpeechRecognizer otherwise).
final class LiveCaptionEnglishRecognizer: LiveCaptionRecognizing, @unchecked Sendable {
    static let locale = Locale(identifier: "en-US")

    private let legacy: SFSpeechRecognizer?
    private let lock = NSLock()

    private init(legacy: SFSpeechRecognizer?) {
        self.legacy = legacy
    }

    static func authorizationStatus() -> LiveCaptionSpeechAuthorization {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unsupported
        }
    }

    static func requestAuthorization() async -> LiveCaptionSpeechAuthorization {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized: cont.resume(returning: .authorized)
                case .denied: cont.resume(returning: .denied)
                case .restricted: cont.resume(returning: .restricted)
                case .notDetermined: cont.resume(returning: .notDetermined)
                @unknown default: cont.resume(returning: .unsupported)
                }
            }
        }
    }

    static func make() async throws -> LiveCaptionEnglishRecognizer {
        if #available(iOS 26.0, macOS 26.0, *) {
            if let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                let installed = await SpeechTranscriber.installedLocales
                if !installed.contains(where: { $0.identifier(.bcp47) == loc.identifier(.bcp47) }) {
                    let t = SpeechTranscriber(locale: loc, preset: .transcription)
                    if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                        try await req.downloadAndInstall()
                    }
                }
                return LiveCaptionEnglishRecognizer(legacy: nil)
            }
        }

        var auth = authorizationStatus()
        if auth == .notDetermined {
            auth = await requestAuthorization()
        }
        guard auth == .authorized else {
            throw LiveCaptionEngineError.speechUnauthorized
        }
        guard let rec = SFSpeechRecognizer(locale: locale) else {
            throw LiveCaptionEngineError.unavailable("本机不支持英语语音识别")
        }
        // Prefer on-device; still allow network ASR if on-device is unavailable so EN accuracy stays high.
        return LiveCaptionEnglishRecognizer(legacy: rec)
    }

    func prepare() async throws {}

    func transcribe(samples: [Float]) async throws -> String {
        guard !samples.isEmpty, !LiveCaptionAudio.isSilent(samples) else { return "" }
        if #available(iOS 26.0, macOS 26.0, *), legacy == nil {
            return try await analyze(samples)
        }
        guard let legacy, let buf = Self.buffer(samples) else { return "" }
        let req = SFSpeechAudioBufferRecognitionRequest()
        if legacy.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        req.shouldReportPartialResults = false
        req.taskHint = .dictation
        req.append(buf)
        req.endAudio()

        final class Once: @unchecked Sendable {
            var done = false
            var task: SFSpeechRecognitionTask?
            let lock = NSLock()
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            once.task = legacy.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    if once.claim() { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            // Bound runaway tasks (live captions must stay snappy).
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if once.claim() {
                    once.task?.cancel()
                    cont.resume(returning: "")
                }
            }
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func analyze(_ samples: [Float]) async throws -> String {
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else { return "" }
        let transcriber = SpeechTranscriber(locale: loc, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let buf = Self.buffer(samples, format: format) else { return "" }
        let (inputs, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        async let text: String = transcriber.results.reduce(into: "") { acc, r in
            acc += String(r.text.characters)
        }
        builder.yield(AnalyzerInput(buffer: buf))
        builder.finish()
        if let last = try await analyzer.analyzeSequence(inputs) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try? await analyzer.cancelAndFinishNow()
        }
        return try await text
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat? = nil) -> AVAudioPCMBuffer? {
        guard let src = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: LiveCaptionAudio.sampleRate,
            channels: 1,
            interleaved: false
        ),
            let b = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            b.floatChannelData![0].update(from: p.baseAddress!, count: samples.count)
        }
        guard let format, format != src else { return b }
        guard let conv = AVAudioConverter(from: src, to: format),
              let out = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / LiveCaptionAudio.sampleRate) + 1024
              )
        else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return b
        }
        return err == nil ? out : nil
    }
}

#else

enum LiveCaptionSpeechAuthorization: Sendable {
    case unauthorized
}

final class LiveCaptionEnglishRecognizer: LiveCaptionRecognizing, @unchecked Sendable {
    init() {}
    static func make() async throws -> LiveCaptionEnglishRecognizer {
        throw LiveCaptionEngineError.unavailable("当前平台不支持实时语音识别")
    }
    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> String { "" }
}

#endif
