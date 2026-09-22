import SwiftUI

/// CamWeb 视觉规范：暗色媒体风（近黑底 + 珊瑚强调 + 金色收藏）。
enum AppTheme {
    // MARK: Palette
    static let background = Color(hex: 0x0B0B0F)
    static let surface = Color(hex: 0x16161D)
    static let card = Color(hex: 0x1C1C26)
    static let cardStroke = Color.white.opacity(0.06)
    static let ink = Color(hex: 0xF5F5F7)
    static let inkSecondary = Color(hex: 0x9A9AA8)
    static let accent = Color(hex: 0xFF375F)
    static let accentSoft = Color(hex: 0xFF375F).opacity(0.16)
    static let favorite = Color(hex: 0xFFD60A)
    static let live = Color(hex: 0xFF375F)
    static let danger = Color(hex: 0xFF453A)
    static let success = Color(hex: 0x30D158)

    // MARK: Metrics
    static let screenPadding: CGFloat = 16
    static let screenPaddingRegular: CGFloat = 28
    static let cardRadius: CGFloat = 14
    static let chipRadius: CGFloat = 10
    static let gridSpacing: CGFloat = 14

    static func gutter(_ regular: Bool) -> CGFloat {
        regular ? screenPaddingRegular : screenPadding
    }

    static func grid(_ regular: Bool) -> [GridItem] {
        [GridItem(.adaptive(minimum: regular ? 180 : 160), spacing: gridSpacing)]
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Reusable chrome

struct LiveBadge: View {
    var isTimeout = false
    var body: some View {
        Text(isTimeout ? "超时" : "LIVE")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (isTimeout ? AppTheme.danger : AppTheme.live)
                    .opacity(0.95),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .shadow(color: (isTimeout ? AppTheme.danger : AppTheme.live).opacity(0.45), radius: 6, y: 1)
    }
}

struct CountPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(AppTheme.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassChip()
    }
}

struct GlassChip: View {
    let title: String
    var systemImage: String?
    var highlighted = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption.weight(.bold))
            }
            Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(highlighted ? AppTheme.favorite : AppTheme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassChip(highlighted: highlighted)
    }
}

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    var tint: Color = AppTheme.ink
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.ink)
            if let trailing {
                CountPill(text: trailing)
            }
            Spacer()
        }
    }
}

struct CardBackground: ViewModifier {
    var radius: CGFloat = AppTheme.cardRadius
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.2), .clear, Color.black.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    }
}

struct BrandScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.background.ignoresSafeArea())
            .tint(AppTheme.accent)
            .preferredColorScheme(.dark)
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func appCard(radius: CGFloat = AppTheme.cardRadius) -> some View {
        modifier(CardBackground(radius: radius))
    }

    func brandScreen() -> some View {
        modifier(BrandScreen())
    }
}
