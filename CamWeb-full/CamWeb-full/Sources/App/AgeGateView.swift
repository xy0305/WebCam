import SwiftUI

struct AgeGateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.background, AppTheme.surface.opacity(0.9), AppTheme.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(AppTheme.accentSoft)
                        .frame(width: 108, height: 108)
                    Image(systemName: "18.circle.fill")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .shadow(color: AppTheme.accent.opacity(0.35), radius: 18)

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
                .shadow(color: AppTheme.accent.opacity(0.35), radius: 14, y: 6)
                .padding(.horizontal, 28)

                Spacer()
            }
        }
        .brandScreen()
    }
}
