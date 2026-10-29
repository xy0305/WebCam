import Foundation
import SwiftUI

/// 播放画质与浏览省电偏好。默认 720p + 关闭装饰动画，显著降发热。
enum PlaybackQuality: String, CaseIterable, Identifiable {
    case p480 = "480"
    case p720 = "720"
    case p1080 = "1080"
    case max = "max"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p480: return "480p 省电"
        case .p720: return "720p 推荐"
        case .p1080: return "1080p"
        case .max: return "最高画质"
        }
    }

    var detail: String {
        switch self {
        case .p480: return "最低发热，适合长时间挂着看"
        case .p720: return "清晰度和发热较均衡"
        case .p1080: return "更清晰，机身会更热"
        case .max: return "原流最高档，发热最明显"
        }
    }

    /// nil = 不限制，取最高档
    var maxHeight: Int? {
        switch self {
        case .p480: return 480
        case .p720: return 720
        case .p1080: return 1080
        case .max: return nil
        }
    }
}

@MainActor
final class PlaybackPreferences: ObservableObject {
    static let shared = PlaybackPreferences()

    private static let qualityKey = "camweb.playback.quality"
    private static let coolKey = "camweb.coolBrowsing"
    @Published var quality: PlaybackQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey) }
    }

    /// 关闭频道墙 LIVE/均衡器等无限动画，默认开启。
    @Published var coolBrowsing: Bool {
        didSet { UserDefaults.standard.set(coolBrowsing, forKey: Self.coolKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.qualityKey) ?? PlaybackQuality.p720.rawValue
        quality = PlaybackQuality(rawValue: raw) ?? .p720
        if UserDefaults.standard.object(forKey: Self.coolKey) == nil {
            coolBrowsing = true
        } else {
            coolBrowsing = UserDefaults.standard.bool(forKey: Self.coolKey)
        }
    }

    /// 非主线程也可读，供 HLS 解析使用。
    nonisolated static func playbackMaxHeight() -> Int? {
        let raw = UserDefaults.standard.string(forKey: qualityKey) ?? PlaybackQuality.p720.rawValue
        return PlaybackQuality(rawValue: raw)?.maxHeight
    }

    nonisolated static func isCoolBrowsingEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: coolKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: coolKey)
    }
}

/// 统一判断是否允许装饰性无限动画。
enum MotionPolicy {
    @MainActor
    static var allowDecorative: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if PlaybackPreferences.shared.coolBrowsing { return false }
        return true
    }

    nonisolated static var allowDecorativeNow: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        return !PlaybackPreferences.isCoolBrowsingEnabled()
    }
}
