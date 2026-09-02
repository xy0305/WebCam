import Foundation
import WebKit

struct Account: Equatable {
    var username: String
    var loggedInAt: Date
}

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isLoggedIn = false
    @Published var continueAsGuest = false
    @Published var account: Account?
    @Published var statusText = ""
    @Published var busy = false

    private let accountKey = "camweb.account.name"

    private init() {}

    func restore() async {
        await CookieBridge.syncWebKitToURLSession()
        if CookieBridge.hasSessionCookie() {
            if let name = UserDefaults.standard.string(forKey: accountKey), !name.isEmpty {
                account = Account(username: name, loggedInAt: Date())
                isLoggedIn = true
                return
            }
            if let name = await fetchContextUsername() {
                persistAccount(name)
                return
            }
        }
        isLoggedIn = false
    }

    func markLoggedIn(username: String) {
        persistAccount(username)
        continueAsGuest = false
        statusText = ""
    }

    func enterGuest() {
        continueAsGuest = true
        statusText = ""
    }

    func logout() async {
        await CookieBridge.clearAll()
        UserDefaults.standard.removeObject(forKey: accountKey)
        account = nil
        isLoggedIn = false
        continueAsGuest = false
    }

    func persistAccount(_ username: String) {
        let name = username.lowercased()
        UserDefaults.standard.set(name, forKey: accountKey)
        account = Account(username: name, loggedInAt: Date())
        isLoggedIn = true
        continueAsGuest = false
    }

    func fetchContextUsername() async -> String? {
        guard let url = URL(string: "https://chaturbate.com/api/ts/context/") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        APIClient.applyCommonHeaders(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let keys = ["username", "user", "user_name", "login"]
        for k in keys {
            if let s = obj[k] as? String, !s.isEmpty, s.lowercased() != "anonymous" {
                return s
            }
        }
        if let user = obj["user"] as? [String: Any],
           let s = user["username"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }
}
