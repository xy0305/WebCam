import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var loggingOut = false
    @ObservedObject private var stripchat = StripchatSession.shared
    @ObservedObject private var panda = PandaSession.shared
    @ObservedObject private var pan115 = Pan115Session.shared
    @ObservedObject private var nutstore = NutstoreSession.shared
    @State private var showChaturbateLogin = false
    @State private var showStripchatLogin = false
    @State private var showPandaLogin = false
    @State private var showPan115Login = false
    @State private var pasteKind: CookiePasteKind?
    @State private var pastedCookie = ""
    @State private var cookieAlert: CookieAlert?
    @State private var nutstoreUser = ""
    @State private var nutstorePass = ""

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                chaturbateSection
                stripchatSection
                pandaSection
                pan115Section
                nutstoreSection
                playbackSection
                logoutSection
                footerSection
            }
            .navigationTitle("设置")
            .onAppear {
                nutstoreUser = nutstore.username
                nutstorePass = ""
            }
            .sheet(isPresented: $showChaturbateLogin) {
                WebLoginView { name in
                    showChaturbateLogin = false
                    if let name { auth.markLoggedIn(username: name) }
                }
            }
            .sheet(isPresented: $showStripchatLogin) { StripchatLoginView() }
            .sheet(isPresented: $showPandaLogin) { PandaLoginView() }
            .sheet(isPresented: $showPan115Login) { Pan115LoginView() }
            .alert(
                pasteKind?.title ?? "粘贴 Cookie",
                isPresented: Binding(
                    get: { pasteKind != nil },
                    set: { if !$0 { pasteKind = nil } }
                )
            ) {
                TextField(pasteKind?.placeholder ?? "", text: $pastedCookie, axis: .vertical)
                Button("取消", role: .cancel) { pasteKind = nil }
                Button("保存") { savePastedCookie() }
            } message: {
                Text(pasteKind?.message ?? "")
            }
            .alert(
                cookieAlert?.title ?? "Cookie 无效",
                isPresented: Binding(
                    get: { cookieAlert != nil },
                    set: { if !$0 { cookieAlert = nil } }
                )
            ) {
                Button("好", role: .cancel) { cookieAlert = nil }
            } message: {
                Text(cookieAlert?.message ?? "")
            }
        }
    }

    private var accountSection: some View {
        Section("账号") {
            LabeledContent("状态", value: accountStatus)
            if auth.isLoggedIn {
                LabeledContent("用户名", value: auth.account?.username ?? "-")
            }
            LabeledContent("会话 Cookie", value: CookieBridge.hasSessionCookie() ? "有效" : "无")
        }
    }

    private var chaturbateSection: some View {
        Section("Chaturbate Cookie 登录") {
            LabeledContent("状态", value: chaturbateStatus)
            Button("网页登录 Chaturbate") { showChaturbateLogin = true }
            Button("粘贴 Cookie") { beginPaste(.chaturbate) }
            Text("公开浏览和播放不需要 Cookie。网页登录或粘贴 sessionid，可过验证码、看关注列表。不会保存密码，也不会解锁私密或付费房间。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var stripchatSection: some View {
        Section("Stripchat Cookie 登录") {
            LabeledContent("状态", value: stripchat.hasCookie ? "Cookie 已保存" : "未连接")
            Button("网页登录 Stripchat") { showStripchatLogin = true }
            Button("粘贴 Cookie") { beginPaste(.stripchat) }
            if stripchat.hasCookie {
                Button("断开 Stripchat", role: .destructive) { stripchat.clear() }
            }
            Text("公开浏览和播放不需要 Cookie；Cookie 仅用于你的 Stripchat 收藏。不会保存密码，也不会解锁私密或付费内容。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var pandaSection: some View {
        Section("PandaTV Cookie 登录") {
            LabeledContent("状态", value: pandaStatus)
            Button("网页登录 PandaTV") { showPandaLogin = true }
            Button("粘贴 Cookie") { beginPaste(.panda) }
            if panda.hasCookie {
                Button("断开 PandaTV", role: .destructive) { panda.clear() }
            }
            Text("对照 StripCam：移动端 /my 登录，信号 cookie 是 sessKey。未登录可看公开列表；密码房和需登录的房间仍打不开。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var pan115Section: some View {
        Section("115 网盘") {
            LabeledContent("状态", value: pan115Status)
            Button("网页登录 / 粘贴 Cookie") { showPan115Login = true }
            if pan115.hasCookie {
                Button("断开 115", role: .destructive) { pan115.clear() }
            }
            Text("对照 alist-ios：App 内嵌 Alist，本机 5244 挂 115。Cookie 需含 UID、CID、SEID。不用填外部地址。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var playbackSection: some View {
        Section("播放") {
            LabeledContent("播放器", value: "KSPlayer")
            LabeledContent("录制", value: "HLS 源流切片")
        }
    }

    private var nutstoreSection: some View {
        Section("坚果云同步") {
            LabeledContent("状态", value: nutstoreStatus)
            TextField("坚果云邮箱", text: $nutstoreUser)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(
                nutstore.hasPassword && nutstorePass.isEmpty ? "已保存应用密码（留空则不改）" : "应用密码",
                text: $nutstorePass
            )
            .textContentType(.password)
            Button("保存账号") {
                nutstore.save(username: nutstoreUser, appPassword: nutstorePass)
                nutstorePass = ""
            }
            Button("测试连接") {
                Task {
                    nutstore.save(username: nutstoreUser, appPassword: nutstorePass)
                    nutstorePass = ""
                    _ = await nutstore.testConnection()
                }
            }
            Button("立即同步") {
                Task { await NutstoreSyncCoordinator.syncAll() }
            }
            .disabled(!nutstore.isConfigured || nutstore.isBusy)
            if nutstore.isConfigured {
                Button("清除配置", role: .destructive) {
                    nutstore.clear()
                    nutstoreUser = ""
                    nutstorePass = ""
                }
            }
            if let message = nutstore.lastMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let at = nutstore.lastSyncAt {
                LabeledContent("上次同步", value: at.formatted(date: .abbreviated, time: .shortened))
            }
            Text("证书不同时 iCloud 不互通。在 iPhone、iPad 各填一次同一坚果云账号的「应用密码」（坚果云 → 账户信息 → 第三方应用管理），即可同步关注/收藏/标签。密码存在本机。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var nutstoreStatus: String {
        if nutstore.isBusy { return "同步中…" }
        if nutstore.isConfigured { return "已配置 \(nutstore.username)" }
        return "未配置"
    }

    private var logoutSection: some View {
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
                Button("去登录") { auth.continueAsGuest = false }
            }
        }
    }

    private var footerSection: some View {
        Section {
            Text("登录只为带上你自己的官网会话。不会保存密码。私密/付费房间不会被解锁。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var accountStatus: String {
        if auth.isLoggedIn { return "已登录" }
        if auth.continueAsGuest { return "游客" }
        return "未登录"
    }

    private var chaturbateStatus: String {
        if let name = auth.account?.username, auth.isLoggedIn { return "已登录 \(name)" }
        if CookieBridge.hasSessionCookie() { return "Cookie 已保存" }
        return "未连接"
    }

    private var pandaStatus: String {
        if let name = panda.userName, panda.hasCookie { return "已登录 \(name)" }
        if panda.hasCookie { return "Cookie 已保存" }
        return "未连接"
    }

    private var pan115Status: String {
        if pan115.hasCookie, !pan115.userName.isEmpty { return "已登录 \(pan115.userName)" }
        if pan115.hasCookie { return "Cookie 已保存" }
        return "未连接"
    }

    private func beginPaste(_ kind: CookiePasteKind) {
        pastedCookie = ""
        pasteKind = kind
    }

    private func savePastedCookie() {
        guard let kind = pasteKind else { return }
        pasteKind = nil
        switch kind {
        case .chaturbate:
            Task { await saveChaturbateCookie() }
        case .stripchat:
            if !stripchat.save(pastedCookie) { cookieAlert = .invalidStripchat }
        case .panda:
            if !panda.save(pastedCookie) { cookieAlert = .invalidPanda }
        }
    }

    private func saveChaturbateCookie() async {
        guard CookieBridge.saveChaturbateCookie(pastedCookie) else {
            cookieAlert = .invalidChaturbate
            return
        }
        if let name = await auth.fetchContextUsername() {
            auth.markLoggedIn(username: name)
        } else {
            auth.markLoggedIn(username: "chaturbate")
        }
    }
}

private enum CookiePasteKind: Identifiable {
    case chaturbate, stripchat, panda
    var id: Self { self }
    var title: String {
        switch self {
        case .chaturbate: return "粘贴 Chaturbate Cookie"
        case .stripchat: return "粘贴 Stripchat Cookie"
        case .panda: return "粘贴 PandaTV Cookie"
        }
    }
    var placeholder: String {
        switch self {
        case .chaturbate: return "sessionid=...; csrftoken=..."
        case .stripchat: return "name=value; name2=value2"
        case .panda: return "sessKey=..."
        }
    }
    var message: String {
        switch self {
        case .chaturbate: return "粘贴浏览器中 chaturbate.com 的完整 Cookie，必须包含 sessionid。"
        case .stripchat: return "粘贴浏览器中 Stripchat 的完整 Cookie，不要带 Set-Cookie: 前缀。"
        case .panda: return "粘贴浏览器中 pandalive.co.kr 的完整 Cookie，必须包含 sessKey。"
        }
    }
}

private enum CookieAlert {
    case invalidChaturbate, invalidStripchat, invalidPanda
    var title: String {
        switch self {
        case .invalidChaturbate: return "Chaturbate Cookie 无效"
        case .invalidStripchat: return "Cookie 格式无效"
        case .invalidPanda: return "PandaTV Cookie 无效"
        }
    }
    var message: String {
        switch self {
        case .invalidChaturbate: return "必须包含 sessionid= 这一项。"
        case .invalidStripchat: return "请输入至少一个 name=value 格式的 Cookie。"
        case .invalidPanda: return "必须包含 sessKey= 这一项。"
        }
    }
}
