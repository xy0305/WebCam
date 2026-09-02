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

    /// HLS CDN 请求头：不要 Origin / CSRF / JSON Accept，否则 edge 会 403
    static var hlsHeaders: [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Referer": "https://chaturbate.com/",
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

    /// 拉 HLS playlist / 分片。不带 CSRF、Origin，避免 CDN 403。
    static func hlsData(for url: URL, retry: Int = 1) async throws -> (Data, HTTPURLResponse) {
        var last: Error = URLError(.badServerResponse)
        for attempt in 0...retry {
            do {
                var r = URLRequest(url: url)
                r.cachePolicy = .reloadIgnoringLocalCacheData
                r.timeoutInterval = 20
                for (k, v) in hlsHeaders {
                    r.setValue(v, forHTTPHeaderField: k)
                }
                let (data, resp) = try await URLSession.shared.data(for: r)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (http.statusCode == 403 || http.statusCode >= 500), attempt < retry {
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 400_000_000))
                    continue
                }
                return (data, http)
            } catch {
                last = error
                if attempt < retry {
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 400_000_000))
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
