import Foundation

enum APIClient {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static var commonHeaders: [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json,text/plain,*/*",
            "Referer": "https://chaturbate.com/",
            "Origin": "https://chaturbate.com",
        ]
    }

    static func applyCommonHeaders(_ req: inout URLRequest) {
        for (k, v) in commonHeaders {
            if req.value(forHTTPHeaderField: k) == nil {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let csrf = CookieBridge.csrfToken() {
            req.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        }
    }

    static func data(for req: URLRequest, retry: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var last: Error = URLError(.badServerResponse)
        for attempt in 0...retry {
            do {
                var r = req
                applyCommonHeaders(&r)
                r.timeoutInterval = 20
                let (data, resp) = try await URLSession.shared.data(for: r)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 403 || http.statusCode >= 500, attempt < retry {
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 600_000_000))
                    continue
                }
                return (data, http)
            } catch {
                last = error
                if attempt < retry {
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 600_000_000))
                }
            }
        }
        throw last
    }

    static func json(_ req: URLRequest) async throws -> Any {
        let (data, http) = try await data(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw StreamSourceError.badResponse
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
