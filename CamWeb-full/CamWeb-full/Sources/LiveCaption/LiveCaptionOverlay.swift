import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Bottom-centered Chinese caption overlay for the live player.
struct LiveCaptionOverlay: View {
    let line: LiveCaptionLine?
    let statusMessage: String
    let reduceMotion: Bool
    /// When false (default), never show English interim — Chinese only.
    var allowEnglish: Bool = false

    private var caption: String {
        guard let line else { return "" }
        return line.displayText(allowEnglish: allowEnglish)
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.black.opacity(0.55))
                        )
                        .accessibilityLabel(line?.showsChinese == true ? "实时翻译" : "实时识别")
                        .accessibilityValue(caption)
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.28)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 72)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: line?.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: statusMessage)
        .allowsHitTesting(false)
    }
}

/// Hosts Apple TranslationSession for iOS 18–25 via `.translationTask`.
struct LiveCaptionTranslationHost: View {
    let bridge: AnyObject?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .modifier(LiveCaptionTranslationTaskModifier(bridge: bridge))
    }
}

private struct LiveCaptionTranslationTaskModifier: ViewModifier {
    let bridge: AnyObject?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            #if canImport(Translation)
            if let bridge = bridge as? LiveCaptionTranslationBridge {
                content
                    .translationTask(bridge.configuration) { session in
                        await bridge.serve(session)
                    }
            } else {
                content
            }
            #else
            content
            #endif
        } else {
            content
        }
    }
}
