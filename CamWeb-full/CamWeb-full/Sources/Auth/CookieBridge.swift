import Foundation
import WebKit

enum CookieBridge {
    static func hasSessionCookie() -> Bool {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        return cookies.contains { $0.name.lowercased() == "sessionid" && !($0.value.isEmpty) }
    }

    static func csrfToken() -> String? {
        HTTPCookieStorage.shared.cookies?.first { $0.name == "csrftoken" }?.value
    }

    @MainActor
    static func syncWebKitToURLSession() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        for c in cookies {
            HTTPCookieStorage.shared.setCookie(c)
        }
    }

    @MainActor
    static func syncURLSessionToWebKit() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        for c in cookies {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.setCookie(c) { cont.resume() }
            }
        }
    }

    @MainActor
    static func clearAll() async {
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
