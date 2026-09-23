import SwiftUI

// MARK: - Motion tokens

enum AppMotion {
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let soft = Animation.spring(response: 0.45, dampingFraction: 0.9)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.75)
    static let shimmer = Animation.linear(duration: 1.4).repeatForever(autoreverses: false)
}

// MARK: - Aurora glow background

struct AuroraBackground: View {
    var intensity: Double = 1
    @State private var shift: CGFloat = 0

    var body: some View {
        ZStack {
            AppTheme.background
            Canvas { context, size in
                let blobs: [(CGPoint, CGFloat, Color)] = [
                    (CGPoint(x: size.width * 0.2 + shift, y: size.height * 0.15), 160, AppTheme.accent.opacity(0.22 * intensity)),
                    (CGPoint(x: size.width * 0.85 - shift, y: size.height * 0.22), 140, AppTheme.accentAlt.opacity(0.16 * intensity)),
                    (CGPoint(x: size.width * 0.55, y: size.height * 0.88), 180, AppTheme.accent.opacity(0.12 * intensity)),
                ]
                for (center, radius, color) in blobs {
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(color)
                    )
                }
            }
            .blur(radius: 40)
            .onAppear {
                withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                    shift = 28
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Staggered entrance

struct StaggeredAppear: ViewModifier {
    var index: Int
    var enabled: Bool

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.94)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                guard enabled else {
                    shown = true
                    return
                }
                withAnimation(AppMotion.spring.delay(Double(min(index, 10)) * 0.045)) {
                    shown = true
                }
            }
    }
}

extension View {
    func staggerAppear(index: Int, enabled: Bool = true) -> some View {
        modifier(StaggeredAppear(index: index, enabled: enabled))
    }
}

// MARK: - Pulsing LIVE badge

struct PulsingLiveBadge: View {
    var isTimeout = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if !isTimeout {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(pulse ? 0.35 : 0.05))
                        .frame(width: pulse ? 10 : 6, height: pulse ? 10 : 6)
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                }
                .frame(width: 12, height: 12)
            }
            Text(isTimeout ? "超时" : "LIVE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (isTimeout ? AppTheme.danger : AppTheme.live)
                .opacity(0.92),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(pulse ? 0.35 : 0.12), lineWidth: 1)
        )
        .shadow(color: (isTimeout ? AppTheme.danger : AppTheme.live).opacity(0.5), radius: pulse ? 8 : 4, y: 1)
        .scaleEffect(pulse ? 1.03 : 1)
        .onAppear {
            guard !isTimeout else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Favorite star burst

struct StarBurst: View {
    var trigger: Bool
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(AppTheme.favorite)
                    .frame(width: 3, height: animating ? 14 : 4)
                    .offset(y: animating ? -18 : -4)
                    .rotationEffect(.degrees(Double(i) * 60))
                    .opacity(animating ? 0 : 0.9)
            }
            Image(systemName: "star.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(AppTheme.favorite)
                .scaleEffect(animating ? 1.25 : 0.2)
                .opacity(animating ? 0 : 1)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, on in
            guard on else { return }
            animating = false
            withAnimation(AppMotion.quick) { animating = true }
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                animating = false
            }
        }
    }
}

// MARK: - Count roll

struct RollingCount: View {
    let value: Int
    var font: Font = .caption.weight(.bold)
    var tint: Color = AppTheme.inkSecondary

    @State private var displayed = 0
    @State private var bounce = false

    var body: some View {
        Text("\(displayed)")
            .font(font)
            .monospacedDigit()
            .foregroundStyle(tint)
            .scaleEffect(bounce ? 1.12 : 1)
            .onAppear { displayed = value }
            .onChange(of: value) { _, new in
                displayed = new
                bounce = false
                withAnimation(AppMotion.quick) { bounce = true }
                Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    withAnimation(AppMotion.quick) { bounce = false }
                }
            }
    }
}

// MARK: - Floating equalizer (live energy)

struct EqualizerBars: View {
    @State private var hop = false
    var tint: Color = AppTheme.accent

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            capsule(hop ? 0.95 : 0.4)
            capsule(hop ? 0.35 : 0.85)
            capsule(hop ? 0.7 : 0.45)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                hop = true
            }
        }
    }

    private func capsule(_ level: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(tint)
            .frame(width: 3, height: 5 + level * 11)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: level)
    }
}

// MARK: - Gradient hairline divider

struct GlowDivider: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, AppTheme.accent.opacity(0.45), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }
}

// MARK: - Press glow card wrapper

struct GlowOnPress: ViewModifier {
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.97 : 1)
            .brightness(pressed ? 0.03 : 0)
            .animation(AppMotion.quick, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            Haptics.tap()
                        }
                    }
                    .onEnded { _ in
                        withAnimation(AppMotion.soft) { pressed = false }
                    }
            )
    }
}

extension View {
    func glowOnPress() -> some View { modifier(GlowOnPress()) }
}

/// 轻微视差：滚动时上层元素微移，克制使用。
struct ScrollParallax: ViewModifier {
    var amount: CGFloat = 18
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: ScrollOffsetKey.self,
                            value: geo.frame(in: .named("scroll")).minY
                        )
                }
            }
            .onPreferenceChange(ScrollOffsetKey.self) { y in
                offset = max(-amount, min(amount, y * 0.08))
            }
            .offset(y: offset * 0.25)
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    func scrollParallax(_ amount: CGFloat = 18) -> some View {
        modifier(ScrollParallax(amount: amount))
    }
}

struct PageFade: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .bottom).combined(with: .scale(scale: 0.98))),
                removal: .opacity
            ))
    }
}

extension View {
    func pageFade(active: Bool) -> some View {
        modifier(PageFade(active: active))
    }
}
