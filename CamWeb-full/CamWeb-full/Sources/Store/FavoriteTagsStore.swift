import Foundation

@MainActor
final class FavoriteTagsStore: ObservableObject {
    static let shared = FavoriteTagsStore()

    private let legacyKey = "camweb.favoriteTags.v1"
    private let sync = CloudListSync(
        localKey: "camweb.favoriteTags.sync.v1",
        cloudKey: "camweb.icloud.favoriteTags.v1"
    )
    private var state = CloudSyncedMap.empty

    @Published private(set) var tags: [String]

    private init() {
        tags = []
        let legacyKey = self.legacyKey
        state = sync.bootstrap {
            var map = CloudSyncedMap.empty
            let now = Date().timeIntervalSince1970
            for tag in UserDefaults.standard.stringArray(forKey: legacyKey) ?? [] {
                let key = Self.normalize(tag)
                if !key.isEmpty { map.upsert(key: key, at: now) }
            }
            return map
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
        publish()
        sync.onRemoteChange = { [weak self] map in
            guard let self else { return }
            self.state = map
            self.publish()
        }
    }

    /// 手动从 iCloud 拉取并合并；云端没有数据时会把本机标签作为首次种子上传。
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

    func contains(_ raw: String) -> Bool {
        let tag = Self.normalize(raw)
        return state.entries[tag]?.isDeleted == false
    }

    func toggle(_ raw: String) {
        let tag = Self.normalize(raw)
        guard !tag.isEmpty else { return }
        if contains(tag) {
            state.remove(key: tag)
        } else {
            state.upsert(key: tag)
        }
        persist()
        publish()
    }

    func remove(_ raw: String) {
        let tag = Self.normalize(raw)
        guard !tag.isEmpty else { return }
        guard contains(tag) else { return }
        state.remove(key: tag)
        persist()
        publish()
    }

    private func persist() {
        state.pruneTombstones()
        sync.commit(state)
    }

    private func publish() {
        tags = state.activeKeys()
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
    }
}
