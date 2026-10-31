import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Bottom-centered Chinese caption overlay for the live player.
struct LiveCaptionOverlay: View {
    let line: LiveCaptionLine?
    let statusMessage: String
    let reduceMotion: Bool

    var body: some View {
        VStack {
            Spacer()
            if let line, !line.chinese.isEmpty {
                Text(line.chinese)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.black.opacity(0.55))
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 72)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityLabel("实时翻译")
                    .accessibilityValue(line.chinese)
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(.bottom, 72)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: line?.id)
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
