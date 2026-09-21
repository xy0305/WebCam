import Foundation

@MainActor
final class FollowingStore: ObservableObject {
    static let shared = FollowingStore()
    private let key = "camweb.following"
    private let cloudKey = "camweb.icloud.following.v1"
    private let cloud = NSUbiquitousKeyValueStore.default
    private var cloudObserver: NSObjectProtocol?
    private var seedTask: Task<Void, Never>?

    @Published private(set) var usernames: [String]
    @Published var lastError: String?

    private init() {
        usernames = Self.normalized(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if let remote = cloud.array(forKey: cloudKey) as? [String] {
            usernames = Self.normalized(remote)
            persistLocal()
        }
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Task { @MainActor [weak self] in self?.reloadCloud(changedKeys: keys) }
        }
        cloud.synchronize()
        // 首次安装先给 iCloud 一点下载时间，避免空设备立即覆盖另一台设备。
        seedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.cloud.object(forKey: self.cloudKey) == nil, !self.usernames.isEmpty else { return }
            self.persistCloud()
        }
    }

    /// 手动从 iCloud 拉取；云端没有数据时，把本机列表作为首次种子上传。
    @discardableResult
    func syncNow() -> Bool {
        guard cloud.synchronize() else { return false }
        if let remote = cloud.array(forKey: cloudKey) as? [String] {
            usernames = Self.normalized(remote)
            persistLocal()
        } else {
            persistCloud()
        }
        return true
    }

    func isFollowing(_ username: String) -> Bool {
        usernames.contains(Self.clean(username))
    }

    func toggle(_ username: String) {
        Task { await toggleSynced(username) }
    }

    func toggleSynced(_ username: String) async {
        let name = Self.clean(username)
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
        var values = usernames
        for room in rooms {
            let name = Self.clean(room.username)
            if !name.isEmpty, !values.contains(name) { values.insert(name, at: 0) }
        }
        usernames = values
        persist()
    }

    private func applyLocal(_ name: String, follow: Bool) {
        guard !name.isEmpty else { return }
        if follow {
            if !usernames.contains(name) { usernames.insert(name, at: 0) }
        } else if let i = usernames.firstIndex(of: name) {
            usernames.remove(at: i)
        }
        persist()
    }

    private func persist() {
        persistLocal()
        persistCloud()
    }

    private func persistLocal() {
        UserDefaults.standard.set(usernames, forKey: key)
    }

    private func persistCloud() {
        cloud.set(usernames, forKey: cloudKey)
        cloud.synchronize()
    }

    private func reloadCloud(changedKeys: [String]?) {
        guard changedKeys == nil || changedKeys?.contains(cloudKey) == true else { return }
        guard let remote = cloud.array(forKey: cloudKey) as? [String] else { return }
        usernames = Self.normalized(remote)
        persistLocal()
    }

    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            let value = clean($0)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
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
