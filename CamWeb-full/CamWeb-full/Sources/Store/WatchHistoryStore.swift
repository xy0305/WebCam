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
    private let key = "camweb.special.v2"
    private let legacyKey = "camweb.special"

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
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else {
            items = (UserDefaults.standard.stringArray(forKey: legacyKey) ?? []).map {
                Item(username: $0, platform: .chaturbate, platformRoomID: nil, imageURL: nil)
            }
        }
    }

    func contains(_ username: String) -> Bool {
        items.contains { $0.username == username.lowercased() }
    }

    func contains(_ room: Room) -> Bool {
        items.contains { $0.username == room.username.lowercased() && $0.platform == room.platform }
    }

    func toggle(_ username: String) {
        toggle(Room(username: username))
    }

    func toggle(_ room: Room) {
        let name = room.username.lowercased()
        if let i = items.firstIndex(where: { $0.username == name && $0.platform == room.platform }) {
            items.remove(at: i)
        } else {
            items.insert(
                Item(username: name, platform: room.platform, platformRoomID: room.platformRoomID, imageURL: room.imageURL),
                at: 0
            )
        }
        persist()
    }

    func remove(_ username: String) {
        items.removeAll { $0.username == username.lowercased() }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
