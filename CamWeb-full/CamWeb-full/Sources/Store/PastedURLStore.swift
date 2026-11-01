import Foundation

/// Recent pasted RTMP / HLS / media URLs (paste-only; never scrapes rooms).
@MainActor
final class PastedURLStore: ObservableObject {
    static let shared = PastedURLStore()

    private let key = "camweb.pasted.urls"
    private let limit = 10

    @Published private(set) var items: [String]

    private init() {
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ raw: String) {
        let value = DirectStreamURL.normalize(raw)
        guard DirectStreamURL.parse(value) != nil else { return }
        items.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        items.insert(value, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        persist()
    }

    func remove(_ raw: String) {
        let value = DirectStreamURL.normalize(raw)
        items.removeAll {
            $0.caseInsensitiveCompare(value) == .orderedSame
                || $0.caseInsensitiveCompare(raw) == .orderedSame
        }
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
