import Foundation

@MainActor
final class FollowingStore: ObservableObject {
    static let shared = FollowingStore()
    private let key = "camweb.following"
    @Published private(set) var usernames: [String]
    @Published var lastError: String?

    private init() {
        usernames = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func isFollowing(_ username: String) -> Bool {
        usernames.contains(username.lowercased())
    }

    func toggle(_ username: String) {
        Task { await toggleSynced(username) }
    }

    func toggleSynced(_ username: String) async {
        let name = username.lowercased()
        let willFollow = !isFollowing(name)
        applyLocal(name, follow: willFollow)
        guard CookieBridge.hasSessionCookie() else { return }
        do {
            try await FollowAPI.set(username: name, follow: willFollow)
            lastError = nil
        } catch {
            applyLocal(name, follow: !willFollow)
            lastError = "官网关注失败：\(error.localizedDescription)"
        }
    }

    func mergeRemote(_ rooms: [Room]) {
        var set = usernames
        for r in rooms where !set.contains(r.username) {
            set.insert(r.username, at: 0)
        }
        usernames = set
        UserDefaults.standard.set(usernames, forKey: key)
    }

    private func applyLocal(_ name: String, follow: Bool) {
        if follow {
            if !usernames.contains(name) { usernames.insert(name, at: 0) }
        } else if let i = usernames.firstIndex(of: name) {
            usernames.remove(at: i)
        }
        UserDefaults.standard.set(usernames, forKey: key)
    }
}

enum FollowAPI {
    static func set(username: String, follow: Bool) async throws {
        let action = follow ? "follow" : "unfollow"
        var req = URLRequest(url: URL(string: "https://chaturbate.com/follow/\(action)/\(username)/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://chaturbate.com/\(username)/", forHTTPHeaderField: "Referer")
        req.httpBody = "room_slug=\(username)&follow=\(action)".data(using: .utf8)
        let (_, http) = try await APIClient.data(for: req, retry: 1)
        if (200..<400).contains(http.statusCode) { return }

        var req2 = URLRequest(url: URL(string: "https://chaturbate.com/follow/\(action)/")!)
        req2.httpMethod = "POST"
        req2.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req2.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req2.setValue("https://chaturbate.com/\(username)/", forHTTPHeaderField: "Referer")
        req2.httpBody = "room_slug=\(username)&follow=\(action)".data(using: .utf8)
        let (_, http2) = try await APIClient.data(for: req2, retry: 0)
        guard (200..<400).contains(http2.statusCode) else { throw StreamSourceError.needLogin }
    }
}
