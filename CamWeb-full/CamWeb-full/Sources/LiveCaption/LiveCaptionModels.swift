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
    func prepare() async throws
    func transcribe(samples: [Float]) async throws -> String
}

protocol LiveCaptionTranslating: Sendable {
    var displayName: String { get }
    func prepare() async throws
    func translate(_ english: String) async throws -> String
    func shutdown()
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
