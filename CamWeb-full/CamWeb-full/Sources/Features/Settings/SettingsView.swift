import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var loggingOut = false
    @ObservedObject private var stripchat = StripchatSession.shared
    @State private var showStripchatLogin = false
    @State private var showPasteCookie = false
    @State private var pastedCookie = ""
    @State private var cookieError = false

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

                Section("Stripchat Cookie 登录") {
                    LabeledContent("状态", value: stripchat.hasCookie ? "Cookie 已保存" : "未连接")
                    Button("网页登录 Stripchat") { showStripchatLogin = true }
                    Button("粘贴 Cookie") { pastedCookie = ""; showPasteCookie = true }
                    if stripchat.hasCookie {
                        Button("断开 Stripchat", role: .destructive) { stripchat.clear() }
                    }
                    Text("公开浏览和播放不需要 Cookie；Cookie 仅用于你的 Stripchat 收藏。不会保存密码，也不会解锁私密或付费内容。")
                        .font(.footnote).foregroundStyle(.secondary)
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
            .sheet(isPresented: $showStripchatLogin) { StripchatLoginView() }
            .alert("粘贴 Stripchat Cookie", isPresented: $showPasteCookie) {
                TextField("name=value; name2=value2", text: $pastedCookie, axis: .vertical)
                Button("取消", role: .cancel) {}
                Button("保存") { cookieError = !stripchat.save(pastedCookie) }
            } message: {
                Text("粘贴浏览器中 Stripchat 的完整 Cookie，不要带 Set-Cookie: 前缀。")
            }
            .alert("Cookie 格式无效", isPresented: $cookieError) {
                Button("好", role: .cancel) {}
            } message: { Text("请输入至少一个 name=value 格式的 Cookie。") }
        }
    }
}
