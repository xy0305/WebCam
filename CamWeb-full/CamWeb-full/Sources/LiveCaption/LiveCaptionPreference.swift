import Foundation
import Observation

/// Speech recognizer used for live captions.
enum LiveCaptionASREngine: String, CaseIterable, Identifiable, Sendable {
    case whisper
    case apple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whisper: return "Whisper（本机，推荐）"
        case .apple: return "Apple 语音识别"
        }
    }
}

/// Whisper CoreML variants (argmaxinc/whisperkit-coreml).
enum LiveCaptionWhisperModel: String, CaseIterable, Identifiable, Sendable {
    /// small.en, 4-bit-ish palettized (~218 MB). Default: best EN accuracy that still runs real-time on M1.
    case smallEn = "openai_whisper-small.en_217MB"
    /// base.en (~147 MB). Faster, slightly less accurate.
    case baseEn = "openai_whisper-base.en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smallEn: return "small.en（约 218 MB，更准）"
        case .baseEn: return "base.en（约 147 MB，更快）"
        }
    }
}

/// English→Chinese translator.
enum LiveCaptionTranslatorEngine: String, CaseIterable, Identifiable, Sendable {
    case qwen
    case apple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .qwen: return "Qwen2.5 1.5B（本机大模型）"
        case .apple: return "Apple 翻译"
        }
    }
}

/// Persisted preferences for English→Chinese live captions. Captions default OFF.
@Observable
final class LiveCaptionPreference {
    static let enabledKey = "camweb.liveCaptionENZH"
    static let asrKey = "camweb.liveCaption.asr"
    static let whisperModelKey = "camweb.liveCaption.whisperModel"
    static let translatorKey = "camweb.liveCaption.translator"

    init() {}

    @ObservationIgnored
    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
        }
    }

    /// Default: Whisper.
    static var asr: LiveCaptionASREngine {
        LiveCaptionASREngine(rawValue: UserDefaults.standard.string(forKey: asrKey) ?? "") ?? .whisper
    }

    /// Default: small.en.
    static var whisperModel: LiveCaptionWhisperModel {
        LiveCaptionWhisperModel(rawValue: UserDefaults.standard.string(forKey: whisperModelKey) ?? "") ?? .smallEn
    }

    /// Default: Qwen (used only when downloaded; otherwise Apple Translation).
    static var translator: LiveCaptionTranslatorEngine {
        LiveCaptionTranslatorEngine(rawValue: UserDefaults.standard.string(forKey: translatorKey) ?? "") ?? .qwen
    }
}
