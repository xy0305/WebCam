import Foundation

@MainActor
final class FavoriteTagsStore: ObservableObject {
    static let shared = FavoriteTagsStore()

    private let key = "camweb.favoriteTags.v1"
    @Published private(set) var tags: [String]

    private init() {
        tags = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func contains(_ raw: String) -> Bool {
        tags.contains(normalize(raw))
    }

    func toggle(_ raw: String) {
        let tag = normalize(raw)
        guard !tag.isEmpty else { return }
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.insert(tag, at: 0)
        }
        UserDefaults.standard.set(tags, forKey: key)
    }

    func remove(_ raw: String) {
        tags.removeAll { $0 == normalize(raw) }
        UserDefaults.standard.set(tags, forKey: key)
    }

    private func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
    }
}
