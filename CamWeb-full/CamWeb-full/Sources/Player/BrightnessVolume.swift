import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

enum ScreenBrightness {
    static var current: CGFloat {
        UIScreen.main.brightness
    }

    static func set(_ value: CGFloat) {
        UIScreen.main.brightness = min(1, max(0, value))
    }
}

enum SystemVolume {
    static var current: Float {
        slider?.value ?? AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        let v = min(1, max(0, value))
        slider?.value = v
        slider?.sendActions(for: .valueChanged)
    }

    private static var slider: UISlider? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
        guard let window else { return nil }
        if let found = window.recursiveVolumeSlider { return found }
        let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        window.addSubview(volumeView)
        return volumeView.recursiveVolumeSlider
    }
}

private extension UIView {
    var recursiveVolumeSlider: UISlider? {
        if let s = self as? UISlider { return s }
        for child in subviews {
            if let s = child.recursiveVolumeSlider { return s }
        }
        return nil
    }
}

enum EdgeSwipeKind {
    case brightness
    case volume
}

struct EdgeSwipeHud: View {
    var kind: EdgeSwipeKind
    var value: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 8, height: 88)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white)
                        .frame(height: max(4, 88 * value))
                }
                .clipShape(Capsule())
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var icon: String {
        switch kind {
        case .brightness:
            return value < 0.15 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if value < 0.01 { return "speaker.slash.fill" }
            if value < 0.35 { return "speaker.wave.1.fill" }
            if value < 0.7 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}
