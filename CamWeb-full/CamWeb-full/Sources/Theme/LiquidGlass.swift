import SwiftUI

// MARK: - Liquid Glass material system

enum GlassStyle {
    static let corner: CGFloat = 18
    static let chipCorner: CGFloat = 22
    /// 淡雅高光：珠光白，低对比
    static let edgeLight = Color(hex: 0xE8F0F8).opacity(0.32)
    static let edgeShade = Color(hex: 0x1A2433).opacity(0.25)
    static let fill = Color(hex: 0x8FBCD4).opacity(0.06)
    static let fillStrong = Color(hex: 0x8FBCD4).opacity(0.10)
}

/// 液态玻璃：内描边高光 + 柔和填充 + 轻投影，克制不花哨。
struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = GlassStyle.corner
    var material: Material = .ultraThin
    var strong = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(material)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(strong ? GlassStyle.fillStrong : GlassStyle.fill)
                }
            }
            .overlay {
                // 顶部/左侧高光，模拟玻璃折射边
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [GlassStyle.edgeLight, .clear, GlassStyle.edgeShade],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

/// 更轻的玻璃条（搜索栏 / 标签）
struct GlassChipStyle: ViewModifier {
    var cornerRadius: CGFloat = GlassStyle.chipCorner
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule().fill(Color.white.opacity(highlighted ? 0.12 : 0.06))
                    }
            }
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(highlighted ? 0.35 : 0.2), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }
}

/// 简约按压：轻缩 + 玻璃提亮，无夸张位移。
struct SoftPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

/// 玻璃按钮底
struct GlassButtonChrome: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accent, Color(hex: 0xA8B8D0), AppTheme.accentAlt],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        }
                        .shadow(color: AppTheme.accent.opacity(0.25), radius: 12, y: 5)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(hex: 0x8FBCD4).opacity(0.08))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [GlassStyle.edgeLight, .clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                }
            }
    }
}

// MARK: - Ambient motion (minimal)

/// 极缓的玻璃光泽扫过，用于关键面板。
struct GlassSheen: ViewModifier {
    @State private var sweep: CGFloat = -1.2

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.07), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.45)
                    .offset(x: sweep * geo.size.width)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: false)) {
                            sweep = 1.3
                        }
                    }
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: GlassStyle.corner, style: .continuous))
            }
    }
}

/// 内容切换时的柔焦过渡（分类 / Tab 内容）
struct SoftMorph: ViewModifier {
    var token: AnyHashable

    func body(content: Content) -> some View {
        content
            .id(token)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: token)
    }
}

extension View {
    func liquidGlass(corner: CGFloat = GlassStyle.corner, strong: Bool = false) -> some View {
        modifier(LiquidGlass(cornerRadius: corner, strong: strong))
    }

    func glassChip(highlighted: Bool = false) -> some View {
        modifier(GlassChipStyle(highlighted: highlighted))
    }

    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonChrome(prominent: prominent))
    }

    func glassSheen() -> some View { modifier(GlassSheen()) }

    func softMorph(_ token: AnyHashable) -> some View {
        modifier(SoftMorph(token: token))
    }
}
