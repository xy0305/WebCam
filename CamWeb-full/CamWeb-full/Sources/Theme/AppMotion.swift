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

    var body: some View {
        ZStack {
            AppTheme.background
            // 静态光晕：原先 Canvas + blur + 无限位移动画会持续吃 GPU。
            RadialGradient(
                colors: [
                    AppTheme.accent.opacity(0.20 * intensity),
                    .clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 320
            )
            RadialGradient(
                colors: [
                    AppTheme.accentAlt.opacity(0.14 * intensity),
                    .clear
                ],
                center: UnitPoint(x: 0.9, y: 0.18),
                startRadius: 10,
                endRadius: 280
            )
            RadialGradient(
                colors: [
                    AppTheme.accent.opacity(0.10 * intensity),
                    .clear
                ],
                center: UnitPoint(x: 0.55, y: 1.05),
                startRadius: 40,
                endRadius: 360
            )
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
            .scaleEffect(shown ? 1 : 0.98)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                // 滚动加载后续卡片不要错落延迟，否则列表像“慢慢冒出来”。
                guard enabled, index < 6 else {
                    shown = true
                    return
                }
                withAnimation(AppMotion.quick.delay(Double(index) * 0.02)) {
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
    @ObservedObject private var prefs = PlaybackPreferences.shared
    @State private var pulse = false

    private var allowPulse: Bool {
        !prefs.coolBrowsing && !ProcessInfo.processInfo.isLowPowerModeEnabled && !isTimeout
    }

    var body: some View {
        // 默认走静态 LiveBadge；仅在关闭「浏览省电」且非低电量模式时启用轻脉冲。
        if !allowPulse {
            LiveBadge(isTimeout: isTimeout)
        } else {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(pulse ? 0.3 : 0.08))
                        .frame(width: pulse ? 9 : 5, height: pulse ? 9 : 5)
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                }
                .frame(width: 12, height: 12)
                Text("LIVE")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.live.opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
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

struct SoftGlowRing: ViewModifier {
    var active: Bool
    var tint: Color = AppTheme.accent

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    Capsule()
                        .stroke(tint.opacity(0.4), lineWidth: 1)
                        .shadow(color: tint.opacity(0.22), radius: 6)
                        .transition(.opacity)
                }
            }
            .animation(AppMotion.soft, value: active)
    }
}

extension View {
    func softGlow(_ active: Bool, tint: Color = AppTheme.accent) -> some View {
        modifier(SoftGlowRing(active: active, tint: tint))
    }
}

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
    var tint: Color = AppTheme.accent
    @ObservedObject private var prefs = PlaybackPreferences.shared
    @State private var hop = false

    private var allowHop: Bool {
        !prefs.coolBrowsing && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            if allowHop {
                capsule(hop ? 0.95 : 0.4)
                capsule(hop ? 0.35 : 0.85)
                capsule(hop ? 0.7 : 0.45)
            } else {
                capsule(0.55)
                capsule(0.95)
                capsule(0.4)
            }
        }
        .onAppear {
            guard allowHop else { return }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                hop = true
            }
        }
        .onChange(of: prefs.coolBrowsing) { _, cool in
            if cool { hop = false }
        }
    }

    private func capsule(_ level: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(tint)
            .frame(width: 3, height: 5 + level * 11)
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
