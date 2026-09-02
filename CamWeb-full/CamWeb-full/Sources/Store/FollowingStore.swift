import Foundation

@MainActor
final class FollowingStore: ObservableObject {
    static let shared = FollowingStore()
    private let key = "camweb.following"
    @Published private(set) var usernames: [String]

    private init() {
        usernames = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func isFollowing(_ username: String) -> Bool {
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
}
