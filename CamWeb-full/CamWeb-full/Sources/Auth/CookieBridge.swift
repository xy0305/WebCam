import Foundation
import WebKit

enum CookieBridge {
    private static let snapKey = "camweb.cookie.snap"

    static func hasSessionCookie() -> Bool {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        return cookies.contains { $0.name.lowercased() == "sessionid" && !($0.value.isEmpty) }
    }

    static func csrfToken() -> String? {
        HTTPCookieStorage.shared.cookies?.first { $0.name == "csrftoken" }?.value
    }

    static func restoreSnapshot() {
        guard let rows = UserDefaults.standard.array(forKey: snapKey) as? [[String: Any]] else { return }
        for row in rows {
            var props: [HTTPCookiePropertyKey: Any] = [:]
            if let n = row["name"] as? String { props[.name] = n }
            if let v = row["value"] as? String { props[.value] = v }
            if let d = row["domain"] as? String { props[.domain] = d }
            if let path = row["path"] as? String { props[.path] = path }
            if let exp = row["exp"] as? Double { props[.expires] = Date(timeIntervalSince1970: exp) }
            props[.secure] = (row["secure"] as? Bool) ?? true
            if let c = HTTPCookie(properties: props) {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
    }

    static func snapshot() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let rows: [[String: Any]] = cookies.compactMap { c in
            guard c.domain.contains("chaturbate") || c.domain.contains("mmcdn") || c.name == "sessionid" || c.name == "csrftoken" else {
                return nil
            }
            var row: [String: Any] = [
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "secure": c.isSecure,
            ]
            if let exp = c.expiresDate { row["exp"] = exp.timeIntervalSince1970 }
            return row
        }
        UserDefaults.standard.set(rows, forKey: snapKey)
    }

    @MainActor
    static func syncWebKitToURLSession() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
        snapshot()
    }

    @MainActor
    static func syncURLSessionToWebKit() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in HTTPCookieStorage.shared.cookies ?? [] {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.setCookie(c) { cont.resume() }
            }
        }
    }

    @MainActor
    static func clearAll() async {
        UserDefaults.standard.removeObject(forKey: snapKey)
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { cont in
            store.fetchDataRecords(ofTypes: types) { cont.resume(returning: $0) }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, for: records) { cont.resume() }
        }
    }
}
