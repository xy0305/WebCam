import SwiftUI

struct AgeGateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 1.1)

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
                .shadow(color: AppTheme.accent.opacity(0.28), radius: 16)
                .staggerAppear(index: 0)

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
                        .glassButton(prominent: true)
                        .glassSheen()
                }
                .buttonStyle(SoftPress())
                .padding(.horizontal, 28)
                .staggerAppear(index: 2)

                Spacer()
            }
        }
        .brandScreen()
    }
}
