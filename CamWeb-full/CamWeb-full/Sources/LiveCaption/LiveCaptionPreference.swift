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
    case apple
    case qwen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: return "Apple 翻译（推荐）"
        case .qwen: return "Qwen2.5 1.5B（本机大模型）"
        }
    }
}

/// Caption pacing: readable sentences (default) vs lower latency / more fragmented.
enum LiveCaptionPaceMode: String, CaseIterable, Identifiable, Sendable {
    /// Buffer to a short utterance before MT — clearer meaning, ~2–3.5 s after speech ends.
    case accurate
    /// Shorter ASR windows; may show interim English if「显示原文」is on.
    case fast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accurate: return "更准（整句，默认）"
        case .fast: return "更快（更碎）"
        }
    }
    var subtitle: String {
        switch self {
        case .accurate: return "凑齐一句再翻，意思更清楚，字幕大约慢 2–3.5 秒"
        case .fast: return "更短切段，出字更快，但容易碎、更难读"
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
    static let paceKey = "camweb.liveCaption.pace"
    static let showEnglishKey = "camweb.liveCaption.showEnglish"

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

    /// Default: Apple Translation. Qwen stays optional in Settings.
    static var translator: LiveCaptionTranslatorEngine {
        LiveCaptionTranslatorEngine(rawValue: UserDefaults.standard.string(forKey: translatorKey) ?? "") ?? .apple
    }

    /// Default: 更准 (sentence buffer).
    static var pace: LiveCaptionPaceMode {
        LiveCaptionPaceMode(rawValue: UserDefaults.standard.string(forKey: paceKey) ?? "") ?? .accurate
    }

    /// Default OFF: Chinese-only overlay (no English flash).
    static var showEnglishSource: Bool {
        UserDefaults.standard.bool(forKey: showEnglishKey)
    }
}
