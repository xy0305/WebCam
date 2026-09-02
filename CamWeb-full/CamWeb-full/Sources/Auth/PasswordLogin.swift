import Foundation

enum PasswordLogin {
    static func attempt(username: String, password: String) async throws -> String {
        var home = URLRequest(url: URL(string: "https://chaturbate.com/")!)
        _ = try await APIClient.data(for: home, retry: 1)
        guard let csrf = CookieBridge.csrfToken(), !csrf.isEmpty else {
            throw StreamSourceError.needLogin
        }
        var req = URLRequest(url: URL(string: "https://chaturbate.com/auth/login/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://chaturbate.com/auth/login/", forHTTPHeaderField: "Referer")
        req.httpShouldHandleCookies = true
        let body = [
            "username": username,
            "password": password,
            "csrfmiddlewaretoken": csrf,
            "next": "/",
        ]
        req.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (_, http) = try await APIClient.data(for: req, retry: 0)
        await MainActor.run { }
        if CookieBridge.hasSessionCookie() {
            return username
        }
        if (300..<400).contains(http.statusCode), CookieBridge.hasSessionCookie() {
            return username
        }
        throw StreamSourceError.needLogin
    }
}
