import Foundation
import Security
import SwiftUI
import WebKit

@MainActor
final class StripchatSession: ObservableObject {
    static let shared = StripchatSession()
    @Published private(set) var hasCookie = false
    private let service = "com.xy0305.WebCam.stripchat"
    private let account = "cookie"

    private init() { hasCookie = cookieHeader != nil }

    var cookieHeader: String? {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func save(_ raw: String) -> Bool {
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("=") }
        guard !pairs.isEmpty else { return false }
        let value = pairs.joined(separator: "; ")
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: value.data(using: .utf8)!] as CFDictionary, nil)
        hasCookie = status == errSecSuccess
        return hasCookie
    }

    func clear() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        hasCookie = false
    }
}

struct StripchatLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Stripchat 登录"
    @State private var captured = false

    var body: some View {
        NavigationStack {
            StripchatLoginWebView(title: $title) { cookie in
                if StripchatSession.shared.save(cookie) { captured = true }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captured ? "完成" : "关闭") { dismiss() } } }
        }
    }
}

private struct StripchatLoginWebView: UIViewRepresentable {
    @Binding var title: String
    var onCookie: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(title: $title, onCookie: onCookie) }
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: URL(string: "https://zh.stripchat.com/login")!))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        var title: Binding<String>; let onCookie: (String) -> Void
        init(title: Binding<String>, onCookie: @escaping (String) -> Void) { self.title = title; self.onCookie = onCookie }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            title.wrappedValue = webView.title ?? "Stripchat 登录"
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let selected = cookies.filter { $0.domain.lowercased().contains("stripchat.com") }
                let hasSignal = selected.contains { cookie in
                    cookie.name.localizedCaseInsensitiveContains("amp_") ||
                    ["session", "auth", "token"].contains(where: { signal in cookie.name.localizedCaseInsensitiveContains(signal) })
                }
                guard hasSignal else { return }
                let header = selected.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                DispatchQueue.main.async { self.onCookie(header) }
            }
        }
    }
}
