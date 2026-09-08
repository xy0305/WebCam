import Foundation

@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()

    private let key = "camweb.search.history"
    private let limit = 30

    @Published private(set) var items: [String]

    private init() {
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return }
        items.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        items.insert(value, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        persist()
    }

    func remove(_ query: String) {
        items.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(items, forKey: key)
    }
}
