import SwiftUI
import WebKit

struct Pan115LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = Pan115Session.shared
    @State private var title = "登录 115"
    @State private var pasted = ""
    @State private var showPaste = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Pan115WebLogin(pageTitle: $title) { ok in
                if ok { dismiss() }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("粘贴 Cookie") { showPaste = true }
                }
            }
            .alert("粘贴 115 Cookie", isPresented: $showPaste) {
                TextField("UID=...; CID=...; SEID=...", text: $pasted, axis: .vertical)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if session.save(pasted) {
                        dismiss()
                    } else {
                        errorText = "必须包含 UID、CID、SEID"
                    }
                }
            } message: {
                Text("从浏览器 115.com 复制完整 Cookie，必须含 UID、CID、SEID。App 内嵌 Alist，不用填地址。")
            }
            .alert("Cookie 无效", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }
}

struct Pan115WebLogin: UIViewRepresentable {
    @Binding var pageTitle: String
    var onLoggedIn: (Bool) -> Void

    func makeCoordinator() -> Coord { Coord(pageTitle: $pageTitle, onLoggedIn: onLoggedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://115.com/?ct=login") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        var pageTitle: Binding<String>
        let onLoggedIn: (Bool) -> Void
        private var finished = false

        init(pageTitle: Binding<String>, onLoggedIn: @escaping (Bool) -> Void) {
            self.pageTitle = pageTitle
            self.onLoggedIn = onLoggedIn
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageTitle.wrappedValue = webView.title ?? "登录 115"
            Task { @MainActor in
                guard !finished else { return }
                let store = webView.configuration.websiteDataStore.httpCookieStore
                let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
                    store.getAllCookies { cont.resume(returning: $0) }
                }
                if Pan115Session.shared.saveFromWebCookies(cookies) {
                    finished = true
                    onLoggedIn(true)
                }
            }
        }
    }
}
