import Foundation

/// One finished English→Chinese live caption line.
struct LiveCaptionLine: Sendable, Equatable, Identifiable {
    let id: UUID
    let english: String
    let chinese: String
    /// Approximate media time (seconds) of the audio chunk start, when known.
    let mediaTime: TimeInterval
    let createdAt: Date

    init(
        id: UUID = UUID(),
        english: String,
        chinese: String,
        mediaTime: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.english = english
        self.chinese = chinese
        self.mediaTime = mediaTime
        self.createdAt = createdAt
    }
}

enum LiveCaptionPhase: String, Sendable, Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case stopping
    case unavailable
    case failed
}

struct LiveCaptionSource: Sendable, Equatable {
    var url: URL
    var headers: [String: String]
    var userAgent: String
    /// Play URL token is single-use (Chaturbate): the caption reader must mint its own URL
    /// via the refresher instead of re-opening the player's URL.
    var requiresFreshPlaylist: Bool

    init(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String = "libmpv",
        requiresFreshPlaylist: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.userAgent = userAgent
        self.requiresFreshPlaylist = requiresFreshPlaylist
    }
}

/// Shared EN→ZH live-caption contracts. On-device Speech + Translation + FFmpeg audio reader.
protocol LiveCaptionRecognizing: Sendable {
    /// Window size fed to the recognizer (16 kHz samples).
    var chunkSamples: Int { get }
    /// Samples carried over into the next window so words on the boundary are not cut.
    var overlapSamples: Int { get }
    var displayName: String { get }
    func prepare() async throws
    func transcribe(samples: [Float]) async throws -> String
}

extension LiveCaptionRecognizing {
    var chunkSamples: Int { LiveCaptionAudio.chunkSamples }
    var overlapSamples: Int { 0 }
    var displayName: String { "Apple 语音识别" }
}

protocol LiveCaptionTranslating: Sendable {
    var displayName: String { get }
    func prepare() async throws
    func translate(_ english: String) async throws -> String
    /// `previous` = the last English line, given as context only.
    func translate(_ english: String, previous: String?) async throws -> String
    func shutdown()
}

extension LiveCaptionTranslating {
    func translate(_ english: String, previous: String?) async throws -> String {
        try await translate(english)
    }
}

/// Removes words repeated because of the window overlap ("... going to" + "to the store" → "the store").
enum LiveCaptionOverlap {
    static func dedupe(previous: String?, current: String) -> String {
        guard let previous, !previous.isEmpty else { return current }
        func norm(_ w: Substring) -> String {
            w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let prevWords = previous.split(separator: " ").suffix(4).map(norm)
        let curWords = current.split(separator: " ")
        let curNorm = curWords.map(norm)
        var best = 0
        for k in stride(from: min(prevWords.count, curNorm.count), through: 1, by: -1) {
            if Array(prevWords.suffix(k)) == Array(curNorm.prefix(k)) { best = k; break }
        }
        guard best > 0 else { return current }
        return curWords.dropFirst(best).joined(separator: " ")
    }
}

/// PCM helpers used by the live caption pipeline (16 kHz mono Float32).
enum LiveCaptionAudio {
    static let sampleRate: Double = 16_000
    /// ~2.4 s windows keep Apple on-device ASR snappy without starving the player.
    static let chunkSamples = 38_400
    static let silenceRMSThreshold: Float = 0.008

    static func isSilent(_ samples: ArraySlice<Float>, threshold: Float = silenceRMSThreshold) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count)) < threshold
    }

    static func isSilent(_ samples: [Float], threshold: Float = silenceRMSThreshold) -> Bool {
        isSilent(samples[...], threshold: threshold)
    }
}
