import SwiftUI
import WebKit

struct WebLoginView: View {
    var onFinish: (String?) -> Void
    @State private var title = "登录官网"

    var body: some View {
        NavigationStack {
            WebLoginRepresentable(onFinish: onFinish, pageTitle: $title)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { onFinish(nil) }
                    }
                }
        }
    }
}

struct WebLoginRepresentable: UIViewRepresentable {
    var onFinish: (String?) -> Void
    @Binding var pageTitle: String

    func makeCoordinator() -> Coord { Coord(onFinish: onFinish, pageTitle: $pageTitle) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://chaturbate.com/auth/login/") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        let onFinish: (String?) -> Void
        var pageTitle: Binding<String>
        private var finished = false

        init(onFinish: @escaping (String?) -> Void, pageTitle: Binding<String>) {
            self.onFinish = onFinish
            self.pageTitle = pageTitle
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageTitle.wrappedValue = webView.title ?? "登录"
            Task { @MainActor in
                await CookieBridge.syncWebKitToURLSession()
                guard CookieBridge.hasSessionCookie(), !finished else { return }
                finished = true
                let guessed = await AuthManager.shared.fetchContextUsername()
                    ?? guessedUser(from: webView.url)
                if let guessed {
                    AuthManager.shared.persistAccount(guessed)
                    onFinish(guessed)
                }
            }
        }

        private func guessedUser(from url: URL?) -> String? {
            guard let path = url?.path, path.count > 1 else { return nil }
            let slug = path.split(separator: "/").first.map(String.init) ?? ""
            let blocked: Set<String> = ["auth", "login", "accounts", "api", "tipping", "privacy"]
            if blocked.contains(slug.lowercased()) { return nil }
            return slug.isEmpty ? nil : slug
        }
    }
}
