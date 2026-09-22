import Foundation

/// iCloud KVS 列表快照：按 key 记录更新时间与墓碑，合并时取较新的一侧。
/// 避免两台设备「整表后写覆盖」互相丢关注/收藏。
struct CloudSyncedMap: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var updatedAt: TimeInterval
        var isDeleted: Bool
        var payload: Data?
    }

    var entries: [String: Entry]

    static let empty = CloudSyncedMap(entries: [:])

    static func decode(_ data: Data?) -> CloudSyncedMap? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(CloudSyncedMap.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    mutating func upsert(key: String, payload: Data? = nil, at now: TimeInterval = Date().timeIntervalSince1970) {
        entries[key] = Entry(updatedAt: now, isDeleted: false, payload: payload)
    }

    mutating func remove(key: String, at now: TimeInterval = Date().timeIntervalSince1970) {
        entries[key] = Entry(updatedAt: now, isDeleted: true, payload: nil)
    }

    /// 同 key 取 updatedAt 较新的一方（含墓碑）；一端缺失时保留另一端的增删。
    static func merge(_ a: CloudSyncedMap, _ b: CloudSyncedMap) -> CloudSyncedMap {
        var out = a.entries
        for (key, entry) in b.entries {
            if let existing = out[key], existing.updatedAt > entry.updatedAt {
                continue
            }
            out[key] = entry
        }
        return CloudSyncedMap(entries: out)
    }

    /// 未删除的 key，最近操作在前。
    func activeKeys() -> [String] {
        entries
            .filter { !$0.value.isDeleted }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map(\.key)
    }

    /// 清掉过期墓碑，避免 KVS 体积缓慢膨胀。
    mutating func pruneTombstones(
        olderThan interval: TimeInterval = 30 * 24 * 3600,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        entries = entries.filter { !$0.value.isDeleted || (now - $0.value.updatedAt) < interval }
    }
}

/// 本地 UserDefaults + iCloud KVS 的读写、并集合并与外部变更监听。
@MainActor
final class CloudListSync {
    private let localKey: String
    private let cloudKey: String
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?
    private var seedTask: Task<Void, Never>?
    private var lastCommitted = CloudSyncedMap.empty

    var onRemoteChange: ((CloudSyncedMap) -> Void)?

    init(localKey: String, cloudKey: String) {
        self.localKey = localKey
        self.cloudKey = cloudKey
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        seedTask?.cancel()
    }

    /// 启动时合并本地与云端。云端尚未下载完成时**不会**写云端，避免空设备覆盖另一台。
    /// `migrate` 只在首次升级时把旧格式转成 map。
    func bootstrap(migrate: () -> CloudSyncedMap) -> CloudSyncedMap {
        var local = CloudSyncedMap.decode(UserDefaults.standard.data(forKey: localKey)) ?? .empty
        let migrateFlagKey = localKey + ".migrated"
        if !UserDefaults.standard.bool(forKey: migrateFlagKey) {
            local = CloudSyncedMap.merge(local, migrate())
            UserDefaults.standard.set(true, forKey: migrateFlagKey)
        }
        local.pruneTombstones()

        if let remote = loadRemote() {
            var merged = CloudSyncedMap.merge(local, remote)
            merged.pruneTombstones()
            commit(merged)
            lastCommitted = merged
        } else {
            persistLocal(local)
            lastCommitted = local
            scheduleSeed()
        }

        startObserving()
        cloud.synchronize()
        return lastCommitted
    }

    @discardableResult
    func syncNow(current: CloudSyncedMap) -> (map: CloudSyncedMap, ok: Bool) {
        guard cloud.synchronize() else { return (current, false) }
        if let remote = loadRemote() {
            var merged = CloudSyncedMap.merge(current, remote)
            merged.pruneTombstones()
            commit(merged)
            lastCommitted = merged
            return (merged, true)
        }
        // 云端仍无数据：把本机当作首次种子写入。
        commit(current)
        lastCommitted = current
        return (current, true)
    }

    func commit(_ map: CloudSyncedMap) {
        persistLocal(map)
        if let data = map.encoded() {
            cloud.set(data, forKey: cloudKey)
            cloud.synchronize()
        }
        lastCommitted = map
    }

    private func persistLocal(_ map: CloudSyncedMap) {
        if let data = map.encoded() {
            UserDefaults.standard.set(data, forKey: localKey)
        }
    }

    private func loadRemote() -> CloudSyncedMap? {
        CloudSyncedMap.decode(cloud.data(forKey: cloudKey))
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard keys == nil || keys?.contains(self.cloudKey) == true else { return }
                guard let remote = self.loadRemote() else { return }
                var merged = CloudSyncedMap.merge(self.lastCommitted, remote)
                merged.pruneTombstones()
                if merged != remote {
                    self.commit(merged)
                } else {
                    self.persistLocal(merged)
                    self.lastCommitted = merged
                }
                self.onRemoteChange?(merged)
            }
        }
    }

    /// 首次安装给 iCloud 一点下载时间；云端确实没有新键时，再把本机作为种子上传。
    private func scheduleSeed() {
        seedTask?.cancel()
        seedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.cloud.object(forKey: self.cloudKey) == nil else { return }
            guard !self.lastCommitted.entries.isEmpty else { return }
            self.commit(self.lastCommitted)
        }
    }
}
