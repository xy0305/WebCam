import SwiftUI
import UIKit

/// CamWeb 视觉规范（build 85）：深石墨中性底 + 单一暖琥珀强调色。
/// 所有颜色只在这里定义，界面里不要再写 Color(hex:) / .blue / .red。
enum AppTheme {
    // MARK: Neutrals（石墨，从深到浅）
    /// 页面底色
    static let background = Color(hex: 0x0E0F12)
    /// 分区 / 面板底
    static let surface = Color(hex: 0x16181D)
    /// 卡片 / 列表行
    static let card = Color(hex: 0x1E2128)
    /// 抬升层（按钮底、输入框）
    static let elevated = Color(hex: 0x272B33)
    static let cardStroke = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.06)

    // MARK: Text
    static let ink = Color(hex: 0xF2F3F5)
    static let inkSecondary = Color(hex: 0x9AA0AA)
    static let inkTertiary = Color(hex: 0x6B717C)

    // MARK: Accent（唯一强调色：暖琥珀）
    static let accent = Color(hex: 0xE3A857)
    static let accentStrong = Color(hex: 0xC98A3A)
    static let accentSoft = Color(hex: 0xE3A857).opacity(0.16)
    /// 兼容旧名：不再引入第二种色相，只是强调色的浅一档
    static let accentAlt = Color(hex: 0xF0C892)
    /// 强调色上的文字
    static let onAccent = Color(hex: 0x1A1408)

    // MARK: Semantic
    static let favorite = Color(hex: 0xE3A857)
    static let live = Color(hex: 0xE5484D)
    static let danger = Color(hex: 0xE5484D)
    static let success = Color(hex: 0x46A758)
    static let warning = Color(hex: 0xE3A857)
    /// 次要信息动作（原先的系统蓝）
    static let info = Color(hex: 0x8B95A5)

    // MARK: Player chrome
    static let playerPanelTop = Color(hex: 0x15161A)
    static let playerPanelBottom = Color(hex: 0x0E0F12)
    static let scrim = Color.black.opacity(0.55)

    static var uiBackground: UIColor { UIColor(red: 0x0E / 255, green: 0x0F / 255, blue: 0x12 / 255, alpha: 1) }
    static var uiAccent: UIColor { UIColor(red: 0xE3 / 255, green: 0xA8 / 255, blue: 0x57 / 255, alpha: 1) }

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
        HStack(spacing: 5) {
            if !isTimeout {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
            }
            Text(isTimeout ? "超时" : "LIVE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isTimeout ? AppTheme.danger : AppTheme.live)
                .opacity(0.94),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
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
                        .fill(AppTheme.card)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
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
