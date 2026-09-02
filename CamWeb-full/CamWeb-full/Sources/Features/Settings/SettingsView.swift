import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var loggingOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    LabeledContent("状态", value: auth.isLoggedIn ? "已登录" : (auth.continueAsGuest ? "游客" : "未登录"))
                    if auth.isLoggedIn {
                        LabeledContent("用户名", value: auth.account?.username ?? "-")
                    }
                    LabeledContent("会话 Cookie", value: CookieBridge.hasSessionCookie() ? "有效" : "无")
                }

                Section("播放") {
                    LabeledContent("播放器", value: "KSPlayer")
                    LabeledContent("录制", value: "HLS 源流切片")
                }

                Section {
                    if auth.isLoggedIn || CookieBridge.hasSessionCookie() {
                        Button(role: .destructive) {
                            Task {
                                loggingOut = true
                                await auth.logout()
                                loggingOut = false
                            }
                        } label: {
                            if loggingOut {
                                ProgressView()
                            } else {
                                Text("退出登录")
                            }
                        }
                    } else {
                        Button {
                            auth.continueAsGuest = false
                        } label: {
                            Text("去登录")
                        }
                    }
                }

                Section {
                    Text("登录只为带上你自己的官网会话。不会保存密码。私密/付费房间不会被解锁。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
