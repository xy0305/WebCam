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
        persist()
    }

    func remove(_ raw: String) {
        tags.removeAll { $0 == normalize(raw) }
        persist()
    }

    func applySnapshot(_ values: [String]) {
        let next = values.map(normalize).filter { !$0.isEmpty }.reduce(into: [String]()) { acc, tag in
            if !acc.contains(tag) { acc.append(tag) }
        }
        guard next != tags else { return }
        tags = next
        UserDefaults.standard.set(tags, forKey: key)
    }

    private func persist() {
        UserDefaults.standard.set(tags, forKey: key)
        Pan115DataSync.shared.scheduleUpload()
    }

    private func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
    }
}
