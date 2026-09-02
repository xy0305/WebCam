import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var loggingOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.system(size: 34, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 14) {
                row("账号", auth.isLoggedIn ? (auth.account?.username ?? "已登录") : (auth.continueAsGuest ? "游客" : "未登录"))
                row("播放器", "KSPlayer")
                row("录制", "HLS 源流切片")
                row("会话 Cookie", CookieBridge.hasSessionCookie() ? "有效" : "无")
            }
            .padding(16)
            .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)

            if auth.isLoggedIn || CookieBridge.hasSessionCookie() {
                Button {
                    Task {
                        loggingOut = true
                        await auth.logout()
                        loggingOut = false
                    }
                } label: {
                    Text(loggingOut ? "退出中…" : "退出登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
            } else {
                Button {
                    auth.continueAsGuest = false
                } label: {
                    Text("去登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.pink, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
            }

            Text("登录只为带上你自己的官网会话。不会保存密码。私密/付费房间不会被解锁。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.system(size: 16))
    }
}
