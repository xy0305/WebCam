import SwiftUI

struct AgeGateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "18.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.pink)
            Text("仅限 18 岁以上")
                .font(.system(size: 28, weight: .bold))
            Text("本应用用于个人观看公开直播。继续即表示你已满 18 周岁。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                appState.acceptAge()
            } label: {
                Text("我已满 18 岁，进入")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Color.pink, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            Spacer()
        }
        .background(Color.white.ignoresSafeArea())
    }
}
