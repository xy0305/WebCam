import Foundation
import Observation

/// Persisted preference for English→Chinese live captions. Default OFF.
@Observable
final class LiveCaptionPreference {
    static let enabledKey = "camweb.liveCaptionENZH"

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
}
