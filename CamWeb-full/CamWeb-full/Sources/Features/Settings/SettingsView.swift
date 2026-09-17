import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var loggingOut = false
    @ObservedObject private var stripchat = StripchatSession.shared
    @ObservedObject private var panda = PandaSession.shared
    @State private var showStripchatLogin = false
    @State private var showPandaLogin = false
    @State private var showPasteCookie = false
    @State private var showPastePandaCookie = false
    @State private var pastedCookie = ""
    @State private var pastedPandaCookie = ""
    @State private var cookieError = false
    @State private var pandaCookieError = false

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

                Section("PandaTV Cookie 登录") {
                    LabeledContent("状态", value: panda.hasCookie ? (panda.userName.map { "已登录 \($0)" } ?? "Cookie 已保存") : "未连接")
                    Button("网页登录 PandaTV") { showPandaLogin = true }
                    Button("粘贴 Cookie") { pastedPandaCookie = ""; showPastePandaCookie = true }
                    if panda.hasCookie {
                        Button("断开 PandaTV", role: .destructive) { panda.clear() }
                    }
                    Text("对照 StripCam：移动端 /my 登录，信号 cookie 是 sessKey。未登录可看公开列表；密码房和需登录的房间仍打不开。")
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
            .sheet(isPresented: $showPandaLogin) { PandaLoginView() }
            .alert("粘贴 Stripchat Cookie", isPresented: $showPasteCookie) {
                TextField("name=value; name2=value2", text: $pastedCookie, axis: .vertical)
                Button("取消", role: .cancel) {}
                Button("保存") { cookieError = !stripchat.save(pastedCookie) }
            } message: {
                Text("粘贴浏览器中 Stripchat 的完整 Cookie，不要带 Set-Cookie: 前缀。")
            }
            .alert("粘贴 PandaTV Cookie", isPresented: $showPastePandaCookie) {
                TextField("sessKey=...", text: $pastedPandaCookie, axis: .vertical)
                Button("取消", role: .cancel) {}
                Button("保存") { pandaCookieError = !panda.save(pastedPandaCookie) }
            } message: {
                Text("粘贴浏览器中 pandalive.co.kr 的完整 Cookie，必须包含 sessKey。")
            }
            .alert("Cookie 格式无效", isPresented: $cookieError) {
                Button("好", role: .cancel) {}
            } message: { Text("请输入至少一个 name=value 格式的 Cookie。") }
            .alert("PandaTV Cookie 无效", isPresented: $pandaCookieError) {
                Button("好", role: .cancel) {}
            } message: { Text("必须包含 sessKey= 这一项。") }
        }
    }
}
