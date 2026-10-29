import Foundation
import SwiftUI

/// 浏览省电偏好：关闭频道墙装饰性循环动画，降低发热。播放画质不受影响（始终最高档）。
@MainActor
final class PlaybackPreferences: ObservableObject {
    static let shared = PlaybackPreferences()

    private static let coolKey = "camweb.coolBrowsing"

    /// 关闭频道墙 LIVE/均衡器等无限动画，默认开启。
    @Published var coolBrowsing: Bool {
        didSet { UserDefaults.standard.set(coolBrowsing, forKey: Self.coolKey) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.coolKey) == nil {
            coolBrowsing = true
        } else {
            coolBrowsing = UserDefaults.standard.bool(forKey: Self.coolKey)
        }
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
