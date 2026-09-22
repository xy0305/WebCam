import Foundation

@MainActor
final class FollowingStore: ObservableObject {
    static let shared = FollowingStore()
    private let legacyKey = "camweb.following"
    private let legacyCloudKey = "camweb.icloud.following.v1"
    private let sync = CloudListSync(
        localKey: "camweb.following.sync.v1",
        cloudKey: "camweb.icloud.following.v2"
    )
    private var state = CloudSyncedMap.empty

    @Published private(set) var usernames: [String]
    @Published var lastError: String?

    private init() {
        usernames = []
        let legacyKey = self.legacyKey
        let legacyCloudKey = self.legacyCloudKey
        state = sync.bootstrap {
            var map = CloudSyncedMap.empty
            let now = Date().timeIntervalSince1970
            for name in UserDefaults.standard.stringArray(forKey: legacyKey) ?? [] {
                let key = Self.clean(name)
                if !key.isEmpty { map.upsert(key: key, at: now) }
            }
            if let remote = NSUbiquitousKeyValueStore.default.array(forKey: legacyCloudKey) as? [String] {
                for name in remote {
                    let key = Self.clean(name)
                    if !key.isEmpty { map.upsert(key: key, at: now) }
                }
            }
            return map
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: legacyCloudKey)
        publish()
        sync.onRemoteChange = { [weak self] map in
            guard let self else { return }
            self.state = map
            self.publish()
        }
    }

    /// 手动从 iCloud 拉取并合并；云端没有数据时会把本机列表作为首次种子上传。
    @discardableResult
    func syncNow() -> Bool {
        let result = sync.syncNow(current: state)
        state = result.map
        publish()
        return result.ok
    }

    var cloudSnapshot: CloudSyncedMap { state }

    func applyCloudSnapshot(_ remote: CloudSyncedMap) {
        state = CloudSyncedMap.merge(state, remote)
        state.pruneTombstones()
        persist()
        publish()
    }

    func isFollowing(_ username: String) -> Bool {
        let name = Self.clean(username)
        return state.entries[name]?.isDeleted == false
    }

    func toggle(_ username: String) {
        Task { await toggleSynced(username) }
    }

    func toggleSynced(_ username: String) async {
        let name = Self.clean(username)
        guard !name.isEmpty else { return }
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
        for room in rooms {
            let name = Self.clean(room.username)
            guard !name.isEmpty else { continue }
            if !isFollowing(name) {
                state.upsert(key: name)
            }
        }
        persist()
        publish()
    }

    private func applyLocal(_ name: String, follow: Bool) {
        guard !name.isEmpty else { return }
        if follow {
            state.upsert(key: name)
        } else {
            state.remove(key: name)
        }
        persist()
        publish()
    }

    private func persist() {
        state.pruneTombstones()
        sync.commit(state)
    }

    private func publish() {
        usernames = state.activeKeys()
    }

    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
