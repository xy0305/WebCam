import Foundation

@MainActor
final class WatchHistoryStore: ObservableObject {
    static let shared = WatchHistoryStore()
    private let key = "camweb.history"
    private let limit = 80

    struct Item: Codable, Identifiable, Hashable {
        var username: String
        var playedAt: TimeInterval
        var id: String { username }
    }

    @Published private(set) var items: [Item]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    func record(_ username: String) {
        let name = username.lowercased()
        guard name.count >= 2 else { return }
        items.removeAll { $0.username == name }
        items.insert(Item(username: name, playedAt: Date().timeIntervalSince1970), at: 0)
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
}

@MainActor
final class SpecialFollowStore: ObservableObject {
    static let shared = SpecialFollowStore()
    private let key = "camweb.special"

    @Published private(set) var usernames: [String]

    private init() {
        usernames = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func contains(_ username: String) -> Bool {
        usernames.contains(username.lowercased())
    }

    func toggle(_ username: String) {
        let name = username.lowercased()
        if let i = usernames.firstIndex(of: name) {
            usernames.remove(at: i)
        } else {
            usernames.insert(name, at: 0)
        }
        UserDefaults.standard.set(usernames, forKey: key)
    }

    func remove(_ username: String) {
        usernames.removeAll { $0 == username.lowercased() }
        UserDefaults.standard.set(usernames, forKey: key)
    }
}
