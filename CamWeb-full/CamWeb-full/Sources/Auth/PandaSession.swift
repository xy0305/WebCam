import Foundation
import Security
import SwiftUI
import WebKit

final class PandaSession: ObservableObject {
    static let shared = PandaSession()
    @Published private(set) var hasCookie = false
    @Published private(set) var userName: String?

    private let service = "com.xy0305.WebCam.panda"
    private let account = "cookie"
    private let lock = NSLock()
    private var cachedCookie: String?

    private init() {
        cachedCookie = loadCookie()
        hasCookie = cachedCookie != nil
    }

    var cookieHeader: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedCookie
    }

    func save(_ raw: String) -> Bool {
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("=") }
        guard pairs.contains(where: { $0.lowercased().hasPrefix("sesskey=") }) else { return false }
        let value = pairs.joined(separator: "; ")
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: value.data(using: .utf8)!
        ] as CFDictionary, nil)
        lock.lock(); cachedCookie = status == errSecSuccess ? value : nil; lock.unlock()
        DispatchQueue.main.async { self.hasCookie = status == errSecSuccess }
        if status == errSecSuccess {
            Task { await self.refreshAccount() }
        }
        return status == errSecSuccess
    }

    func clear() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        lock.lock(); cachedCookie = nil; lock.unlock()
        DispatchQueue.main.async {
            self.hasCookie = false
            self.userName = nil
        }
    }

    func refreshAccount() async {
        let name = await PandaAPI.loginName()
        await MainActor.run { self.userName = name }
    }

    private func loadCookie() -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
}

struct PandaLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = "PandaTV 登录"
    @State private var captured = false

    var body: some View {
        NavigationStack {
            PandaLoginWebView(title: $title) { cookie in
                if PandaSession.shared.save(cookie) { captured = true }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(captured ? "完成" : "关闭") { dismiss() }
                }
            }
        }
    }
}

private struct PandaLoginWebView: UIViewRepresentable {
    @Binding var title: String
    var onCookie: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(title: $title, onCookie: onCookie) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = PandaAPI.mobileUserAgent
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: URL(string: "https://m.pandalive.co.kr/my")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var title: Binding<String>
        let onCookie: (String) -> Void
        init(title: Binding<String>, onCookie: @escaping (String) -> Void) {
            self.title = title
            self.onCookie = onCookie
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            title.wrappedValue = webView.title ?? "PandaTV 登录"
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let selected = cookies.filter { $0.domain.lowercased().contains("pandalive.co.kr") }
                guard selected.contains(where: { $0.name == "sessKey" && !$0.value.isEmpty }) else { return }
                let header = selected.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                DispatchQueue.main.async { self.onCookie(header) }
            }
        }
    }
}
