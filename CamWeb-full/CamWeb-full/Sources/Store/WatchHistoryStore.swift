import Foundation

@MainActor
final class WatchHistoryStore: ObservableObject {
    static let shared = WatchHistoryStore()
    private let key = "camweb.history.v2"
    private let legacyKey = "camweb.history"
    private let limit = 80

    struct Item: Codable, Identifiable, Hashable {
        var username: String
        var platform: CamPlatform
        var platformRoomID: String?
        var imageURL: String?
        var playedAt: TimeInterval
        var id: String { "\(platform.rawValue):\(username)" }

        var room: Room {
            Room(
                platform: platform,
                platformRoomID: platformRoomID,
                username: username,
                displayName: username,
                imageURL: imageURL
            )
        }
    }

    @Published private(set) var items: [Item]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let decoded = try? JSONDecoder().decode([LegacyItem].self, from: data) {
            items = decoded.map {
                Item(username: $0.username, platform: .chaturbate, platformRoomID: nil, imageURL: nil, playedAt: $0.playedAt)
            }
        } else {
            items = []
        }
    }

    func record(_ room: Room) {
        let name = room.username.lowercased()
        guard name.count >= 2 else { return }
        items.removeAll { $0.username == name && $0.platform == room.platform }
        items.insert(
            Item(
                username: name,
                platform: room.platform,
                platformRoomID: room.platformRoomID,
                imageURL: room.imageURL,
                playedAt: Date().timeIntervalSince1970
            ),
            at: 0
        )
        if items.count > limit { items = Array(items.prefix(limit)) }
        persist()
    }

    func remove(_ username: String) {
        items.removeAll { $0.username == username.lowercased() }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private struct LegacyItem: Codable {
        var username: String
        var playedAt: TimeInterval
    }
}

@MainActor
final class SpecialFollowStore: ObservableObject {
    static let shared = SpecialFollowStore()
    private let legacyKey = "camweb.special.v2"
    private let olderLegacyKey = "camweb.special"
    private let legacyCloudKey = "camweb.icloud.special.v1"
    private let sync = CloudListSync(
        localKey: "camweb.special.sync.v1",
        cloudKey: "camweb.icloud.special.v2"
    )
    private var state = CloudSyncedMap.empty

    struct Item: Codable, Identifiable, Hashable {
        var username: String
        var platform: CamPlatform
        var platformRoomID: String?
        var imageURL: String?
        var id: String { "\(platform.rawValue):\(username)" }

        var room: Room {
            Room(
                platform: platform,
                platformRoomID: platformRoomID,
                username: username,
                displayName: username,
                imageURL: imageURL
            )
        }
    }

    @Published private(set) var items: [Item]

    var usernames: [String] { items.map(\.username) }

    private init() {
        items = []
        let legacyKey = self.legacyKey
        let olderLegacyKey = self.olderLegacyKey
        let legacyCloudKey = self.legacyCloudKey
        state = sync.bootstrap {
            var map = CloudSyncedMap.empty
            let now = Date().timeIntervalSince1970
            if let data = UserDefaults.standard.data(forKey: legacyKey),
               let decoded = try? JSONDecoder().decode([Item].self, from: data) {
                for item in decoded { map.upsertLegacy(item, at: now) }
            }
            for name in UserDefaults.standard.stringArray(forKey: olderLegacyKey) ?? [] {
                map.upsertLegacy(Item(username: name, platform: .chaturbate, platformRoomID: nil, imageURL: nil), at: now)
            }
            if let data = NSUbiquitousKeyValueStore.default.data(forKey: legacyCloudKey),
               let decoded = try? JSONDecoder().decode([Item].self, from: data) {
                for item in decoded { map.upsertLegacy(item, at: now) }
            }
            return map
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: olderLegacyKey)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: legacyCloudKey)
        publish()
        sync.onRemoteChange = { [weak self] map in
            guard let self else { return }
            self.state = map
            self.publish()
        }
    }

    /// 手动从 iCloud 拉取并合并；云端没有数据时会把本机收藏作为首次种子上传。
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

    func contains(_ username: String) -> Bool {
        let name = username.lowercased()
        return items.contains { $0.username == name }
    }

    func contains(_ room: Room) -> Bool {
        items.contains { $0.username == room.username.lowercased() && $0.platform == room.platform }
    }

    func toggle(_ username: String) {
        toggle(Room(username: username))
    }

    func toggle(_ room: Room) {
        let name = room.username.lowercased()
        guard !name.isEmpty else { return }
        let id = "\(room.platform.rawValue):\(name)"
        if state.entries[id]?.isDeleted == false {
            state.remove(key: id)
        } else {
            let item = Item(username: name, platform: room.platform, platformRoomID: room.platformRoomID, imageURL: room.imageURL)
            state.upsert(key: id, payload: Self.encode(item))
        }
        persist()
        publish()
    }

    func remove(_ username: String) {
        let name = username.lowercased()
        let ids = state.entries.keys.filter { $0.hasSuffix(":\(name)") || $0 == name }
        guard !ids.isEmpty else { return }
        for id in ids where state.entries[id]?.isDeleted == false {
            state.remove(key: id)
        }
        persist()
        publish()
    }

    private func persist() {
        state.pruneTombstones()
        sync.commit(state)
    }

    private func publish() {
        items = state.activeKeys().compactMap { key in
            if let payload = state.entries[key]?.payload, let item = Self.decode(payload) {
                return Self.normalized(item)
            }
            return Self.normalized(Item(username: key, platform: .chaturbate, platformRoomID: nil, imageURL: nil))
        }
    }

    private static func encode(_ item: Item) -> Data? {
        try? JSONEncoder().encode(item)
    }

    private static func decode(_ data: Data) -> Item? {
        try? JSONDecoder().decode(Item.self, from: data)
    }

    private static func normalized(_ item: Item) -> Item {
        var value = item
        value.username = item.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value
    }
}

private extension CloudSyncedMap {
    mutating func upsertLegacy(_ item: SpecialFollowStore.Item, at now: TimeInterval) {
        let name = item.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return }
        var value = item
        value.username = name
        upsert(key: value.id, payload: try? JSONEncoder().encode(value), at: now)
    }
}
