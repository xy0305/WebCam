import Foundation

struct ResolvedStream: Sendable {
    let username: String
    let hlsURL: URL
    let status: String
}

enum StreamSource {
    static func resolve(username: String) async throws -> ResolvedStream {
        var last: Error = StreamSourceError.badResponse
        for _ in 0..<3 {
            do {
                if let s = try? await fromAjax(username: username) { return s }
                return try await fromContext(username: username)
            } catch {
                last = error
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw last
    }

    private static func fromAjax(username: String) async throws -> ResolvedStream {
        var req = URLRequest(url: URL(string: "https://chaturbate.com/get_edge_hls_url_ajax/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://chaturbate.com/\(username)/", forHTTPHeaderField: "Referer")
        req.httpBody = "room_slug=\(username)&bandwidth=high".data(using: .utf8)
        let (data, http) = try await APIClient.data(for: req, retry: 1)
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (obj["room_status"] as? String) ?? "unknown"
        guard status == "public" else { throw StreamSourceError.offline(status) }
        guard let raw = obj["url"] as? String, let url = URL(string: raw), !raw.isEmpty else {
            throw StreamSourceError.blocked
        }
        return ResolvedStream(username: username, hlsURL: url, status: status)
    }

    private static func fromContext(username: String) async throws -> ResolvedStream {
        var req = URLRequest(url: URL(string: "https://chaturbate.com/api/chatvideocontext/\(username)/")!)
        req.setValue("https://chaturbate.com/\(username)/", forHTTPHeaderField: "Referer")
        let (data, http) = try await APIClient.data(for: req, retry: 1)
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (obj["room_status"] as? String) ?? "unknown"
        guard status == "public" else { throw StreamSourceError.offline(status) }
        guard let raw = obj["hls_source"] as? String, let url = URL(string: raw), !raw.isEmpty else {
            throw StreamSourceError.blocked
        }
        return ResolvedStream(username: username, hlsURL: url, status: status)
    }
}
