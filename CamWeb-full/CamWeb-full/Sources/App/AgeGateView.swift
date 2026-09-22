import SwiftUI

struct AgeGateView: View {
    @EnvironmentObject var appState: AppState
    @State private var glow = false

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 1.1)

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(AppTheme.accentSoft)
                        .frame(width: 108, height: 108)
                        .scaleEffect(glow ? 1.1 : 1)
                        .opacity(glow ? 0.65 : 1)
                    Image(systemName: "18.circle.fill")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .shadow(color: AppTheme.accent.opacity(0.35), radius: 18)
                .staggerAppear(index: 0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        glow = true
                    }
                }

                VStack(spacing: 10) {
                    Text("仅限 18 岁以上")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                    Text("CamWeb 用于个人观看公开直播。\n继续即表示你已满 18 周岁。")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 28)
                .staggerAppear(index: 1)

                Button {
                    appState.acceptAge()
                } label: {
                    Text("我已满 18 岁，进入")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [AppTheme.accent, AppTheme.accent.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .glowOnPress()
                .shadow(color: AppTheme.accent.opacity(0.35), radius: 14, y: 6)
                .padding(.horizontal, 28)
                .staggerAppear(index: 2)

                Spacer()
            }
        }
        .brandScreen()
    }
}
