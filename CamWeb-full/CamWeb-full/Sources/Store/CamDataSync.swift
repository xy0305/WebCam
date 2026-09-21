import Foundation

/// 收藏 / 关注 / 标签的可传输快照。115 目录里只放带时间戳的 JSON，
/// 不依赖 iCloud  entitlement，侧载重签名也照样能同步。
struct CamSyncSnapshot: Codable {
    var version: Int = 1
    var savedAt: TimeInterval = Date().timeIntervalSince1970
    var device: String = ""
    var following: [String] = []
    var special: [SpecialFollowStore.Item] = []
    var tags: [String] = []
}

enum CamSyncMerge {
    /// 只增不减：删除要靠「以本机为准」显式覆盖，避免两台设备互相清空。
    static func combine(_ local: CamSyncSnapshot, _ other: CamSyncSnapshot) -> CamSyncSnapshot {
        var out = local
        out.savedAt = max(local.savedAt, other.savedAt)
        out.following = unionValues(local.following, other.following)
        out.special = unionItems(local.special, other.special)
        out.tags = unionValues(local.tags, other.tags)
        return out
    }

    static func isSameContent(_ a: CamSyncSnapshot, _ b: CamSyncSnapshot) -> Bool {
        Set(a.following) == Set(b.following)
            && Set(a.special.map(\.id)) == Set(b.special.map(\.id))
            && Set(a.tags) == Set(b.tags)
    }

    private static func unionValues(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0).inserted }
    }

    private static func unionItems(_ a: [SpecialFollowStore.Item], _ b: [SpecialFollowStore.Item]) -> [SpecialFollowStore.Item] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.id).inserted }
    }
}

@MainActor
final class Pan115DataSync: ObservableObject {
    static let shared = Pan115DataSync()

    static let folderName = "CamWeb"
    private static let filePrefix = "camweb-sync-"
    private static let keepRemoteCopies = 5
    private static let debounceNanoseconds: UInt64 = 15_000_000_000
    private static let launchThrottle: TimeInterval = 180

    private static let enabledKey = "camweb.sync115.enabled"
    private static let summaryKey = "camweb.sync115.summary"
    private static let lastAtKey = "camweb.sync115.lastAt"
    private static let folderCIDKey = "camweb.sync115.cid"
    private static let deviceCodeKey = "camweb.sync115.device"

    enum Reason {
        case launch, manual, afterEdit
    }

    @Published private(set) var busy = false
    @Published private(set) var summary: String = Pan115DataSync.storedSummary
    @Published var enabled: Bool = Pan115DataSync.storedEnabled {
        didSet { UserDefaults.standard.set(enabled, forKey: Pan115DataSync.enabledKey) }
    }

    private var pending: Task<Void, Never>?

    private static var storedSummary: String {
        UserDefaults.standard.string(forKey: summaryKey) ?? "从未同步"
    }

    private static var storedEnabled: Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    var readyToSync: Bool { Pan115Session.shared.hasCookie }

    private static var remoteDir: String {
        Pan115API.join(Pan115Session.shared.rootPath, folderName)
    }

    // MARK: - 快照读写

    func localSnapshot() -> CamSyncSnapshot {
        var snap = CamSyncSnapshot()
        snap.savedAt = Date().timeIntervalSince1970
        snap.device = Self.deviceCode
        snap.following = FollowingStore.shared.usernames
        snap.special = SpecialFollowStore.shared.items
        snap.tags = FavoriteTagsStore.shared.tags
        return snap
    }

    func apply(_ snap: CamSyncSnapshot) {
        FollowingStore.shared.applySnapshot(snap.following)
        SpecialFollowStore.shared.applySnapshot(snap.special)
        FavoriteTagsStore.shared.applySnapshot(snap.tags)
    }

    // MARK: - 同步入口

    /// 编辑后延迟合并上传；连续点多颗星星只发一次请求。
    func scheduleUpload() {
        guard enabled, readyToSync else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            _ = await self?.sync(reason: .afterEdit)
        }
    }

    func sync(reason: Reason) async -> String {
        guard enabled else { return "同步已在设置里关闭" }
        guard readyToSync else { return "先在设置里登录 115 网盘" }
        if reason == .launch {
            let last = UserDefaults.standard.double(forKey: Self.lastAtKey)
            guard Date().timeIntervalSince1970 - last > Self.launchThrottle else { return summary }
        }
        guard !busy else { return "正在同步，稍等" }
        busy = true
        defer { busy = false }
        do {
            let local = localSnapshot()
            guard let remote = try await readRemote() else {
                try await upload(local)
                return record("本机数据已上传到 115（\(counts(local))）")
            }
            let merged = CamSyncMerge.combine(local, remote)
            apply(merged)
            if CamSyncMerge.isSameContent(merged, remote) {
                return record("已与 115 对齐（\(counts(merged))）")
            }
            try await upload(merged)
            return record("已合并上传，115 侧新增 \(merged.following.count - remote.following.count) 关注 / \(merged.special.count - remote.special.count) 收藏")
        } catch {
            return record("同步失败：\(error.localizedDescription)")
        }
    }

    /// 本机覆盖 115：唯一会把「取消收藏」这类删除传出去的入口。
    func pushReplacingRemote() async -> String {
        guard readyToSync else { return "先在设置里登录 115 网盘" }
        guard !busy else { return "正在同步，稍等" }
        busy = true
        defer { busy = false }
        do {
            let local = localSnapshot()
            try await upload(local)
            return record("已用本机覆盖 115（\(counts(local))）")
        } catch {
            return record("覆盖失败：\(error.localizedDescription)")
        }
    }

    func pullReplacingLocal() async -> String {
        guard readyToSync else { return "先在设置里登录 115 网盘" }
        guard !busy else { return "正在同步，稍等" }
        busy = true
        defer { busy = false }
        do {
            guard let remote = try await readRemote() else { return record("115 上还没有快照") }
            apply(remote)
            return record("已用 115 覆盖本机（\(counts(remote))）")
        } catch {
            return record("拉取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 传输

    private func readRemote() async throws -> CamSyncSnapshot? {
        // 列举走 115 网页接口：实时，不吃 Alist 的 meta 缓存，也不要求 /115 挂载存在。
        guard let node = try await newestRemoteNode() else { return nil }
        // 换下载链要 Alist 活着；没有远端快照时不必去碰它。
        if Pan115Session.shared.hasCookie { await Pan115Session.shared.mount115() }
        let data = try await download(node)
        do {
            return try JSONDecoder().decode(CamSyncSnapshot.self, from: data)
        } catch {
            // 认不出来的云端快照绝不能被本机覆盖。
            throw Pan115API.APIError.message("115 上的快照无法解析（\(node.name)），已停止同步以保护数据")
        }
    }

    private func download(_ node: Pan115API.Node) async throws -> Data {
        let path = Pan115API.join(Self.remoteDir, node.name)
        var alistError: String?
        do {
            // 强刷一次目录，把 Alist 里可能缓存下来的"该目录不存在"记录冲掉。
            _ = try? await Pan115API.list(cid: Self.remoteDir, refresh: true)
            let link = try await Pan115API.fileLink(pickCode: path)
            var req = URLRequest(url: link.url)
            req.httpMethod = "GET"
            req.timeoutInterval = 40
            link.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw Pan115API.APIError.badResponse }
            guard (200..<300).contains(http.statusCode), !data.isEmpty else {
                throw Pan115API.APIError.httpStatus(http.statusCode)
            }
            return data
        } catch {
            alistError = error.localizedDescription
        }
        guard !node.pickCode.isEmpty else {
            throw Pan115API.APIError.message("读取快照失败：\(alistError ?? "未知错误")")
        }
        // 兜底走 115 直连换链；CDN 会校验会话，同设备同 IP 时才有机会通过。
        do {
            let url = try await Pan115API.driveDownloadURL(pickCode: node.pickCode)
            return try await Pan115API.driveData(from: url)
        } catch {
            throw Pan115API.APIError.message("读取快照失败：Alist「\(alistError ?? "")」，115 直连「\(error.localizedDescription)」")
        }
    }

    /// 目录不存在就创建（115 cid）；缓存的 cid 失效时重建一次再试。
    private func listRemoteSnapshots() async throws -> [Pan115API.Node] {
        let cid = try await syncFolderCID()
        do {
            return snapshotNodes(try await Pan115API.driveList(cid: cid))
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.folderCIDKey)
            return snapshotNodes(try await Pan115API.driveList(cid: try await syncFolderCID()))
        }
    }

    private func newestRemoteNode() async throws -> Pan115API.Node? {
        try await listRemoteSnapshots().max { $0.name < $1.name }
    }

    private func snapshotNodes(_ kids: [Pan115API.Node]) -> [Pan115API.Node] {
        kids.filter { !$0.isDir && $0.name.hasPrefix(Self.filePrefix) && $0.name.hasSuffix(".json") }
    }

    private func upload(_ snap: CamSyncSnapshot) async throws {
        var cid = try await syncFolderCID()
        let data = try JSONEncoder().encode(snap)
        do {
            try await uploadData(data, folderCID: cid)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.folderCIDKey)
            cid = try await syncFolderCID()
            try await uploadData(data, folderCID: cid)
        }
        try? await pruneRemoteCopies()
    }

    private func uploadData(_ data: Data, folderCID: String) async throws {
        let name = Self.fileName()
        let sha = Pan115API.sha1Hex(data)
        let ticket = try await Pan115API.initUpload(
            fileName: name, size: Int64(data.count), sha1: sha, preSha1: sha, dirID: folderCID
        )
        // 秒传说明 115 上已有同样内容，不必再发一次字节。
        if ticket.rapid { return }
        try await postForm(ticket, name: name, data: data)
    }

    private func postForm(_ info: Pan115API.InitUpload, name: String, data: Data) async throws {
        let host = info.host.hasPrefix("http") ? info.host : "https://\(info.host)"
        guard !info.object.isEmpty, let url = URL(string: host) else { throw Pan115API.APIError.badResponse }
        var fields: [(String, String)] = []
        if !info.accessKeyId.isEmpty { fields.append(("OSSAccessKeyId", info.accessKeyId)) }
        if !info.formPolicy.isEmpty { fields.append(("policy", info.formPolicy)) }
        if !info.formSignature.isEmpty { fields.append(("signature", info.formSignature)) }
        fields.append(("key", info.object))
        if !info.callback.isEmpty { fields.append(("callback", info.callback)) }
        if !info.callbackVar.isEmpty { fields.append(("callback-var", info.callbackVar)) }
        if !info.securityToken.isEmpty { fields.append(("x-oss-security-token", info.securityToken)) }
        fields.append(("name", name))

        let boundary = "----CamWebSync\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        for (key, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(Pan115API.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        if let cookie = Pan115Session.shared.cookieHeader { req.setValue(cookie, forHTTPHeaderField: "Cookie") }

        let (respData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw Pan115API.APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw Pan115API.APIError.httpStatus(http.statusCode) }
        if let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let state = obj["state"] as? Bool, state == false {
            throw Pan115API.APIError.message(obj["error"] as? String ?? "115 拒绝写入快照")
        }
    }

    private func syncFolderCID() async throws -> String {
        if let cached = UserDefaults.standard.string(forKey: Self.folderCIDKey),
           !cached.isEmpty, cached != "0" {
            return cached
        }
        let cid = try await Pan115API.driveEnsureFolder(parent: "0", parts: [Self.folderName])
        UserDefaults.standard.set(cid, forKey: Self.folderCIDKey)
        return cid
    }

    /// 只留最近几份，出错不影响同步本身。
    private func pruneRemoteCopies() async throws {
        for node in try await listRemoteSnapshots().sorted(by: { $0.name < $1.name }).dropLast(Self.keepRemoteCopies) {
            try? await Pan115API.driveDelete(id: node.id)
        }
    }

    // MARK: - 杂项

    private func record(_ text: String) -> String {
        UserDefaults.standard.set(text, forKey: Self.summaryKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAtKey)
        summary = text
        return text
    }

    private func counts(_ snap: CamSyncSnapshot) -> String {
        "关注 \(snap.following.count)·收藏 \(snap.special.count)·标签 \(snap.tags.count)"
    }

    private static var deviceCode: String {
        if let cached = UserDefaults.standard.string(forKey: deviceCodeKey), !cached.isEmpty { return cached }
        let code = String(UUID().uuidString.prefix(4)).lowercased()
        UserDefaults.standard.set(code, forKey: deviceCodeKey)
        return code
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 文件名带时间戳，字典序即时间序；不同设备同秒也不会撞名。
    private static func fileName() -> String {
        "\(filePrefix)\(stamp.string(from: Date()))-\(deviceCode).json"
    }
}
