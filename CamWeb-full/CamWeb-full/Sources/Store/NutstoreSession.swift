import Foundation

/// 坚果云 WebDAV：账号 + 应用密码，同步一份 JSON 快照。
/// 用于证书/Team ID 不同、iCloud KVS 无法互通时的跨设备同步。
@MainActor
final class NutstoreSession: ObservableObject {
    static let shared = NutstoreSession()

    static let baseURL = URL(string: "https://dav.jianguoyun.com/dav/")!
    static let folderName = "CamWeb"
    static let fileName = "camweb-sync.json"

    private let userKey = "camweb.nutstore.user"
    private let passKey = "camweb.nutstore.appPassword"

    @Published private(set) var username: String
    @Published private(set) var hasPassword: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var lastSyncAt: Date?
    @Published var lastMessage: String?

    private var appPassword: String

    private init() {
        username = UserDefaults.standard.string(forKey: userKey) ?? ""
        appPassword = UserDefaults.standard.string(forKey: passKey) ?? ""
        hasPassword = !appPassword.isEmpty
    }

    var isConfigured: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appPassword.isEmpty
    }

    func markBusy(_ busy: Bool) {
        isBusy = busy
    }

    func markSynced() {
        lastSyncAt = Date()
    }

    func setMessage(_ text: String?) {
        lastMessage = text
    }

    var remoteFileURL: URL {
        Self.baseURL.appendingPathComponent(Self.folderName).appendingPathComponent(Self.fileName)
    }

    /// `appPassword` 留空表示不修改已有应用密码。
    func save(username: String, appPassword: String) {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = name
        if !pass.isEmpty {
            self.appPassword = pass
            UserDefaults.standard.set(pass, forKey: passKey)
        }
        self.hasPassword = !self.appPassword.isEmpty
        UserDefaults.standard.set(name, forKey: userKey)
        lastMessage = isConfigured ? "已保存，可点「立即同步」" : "请填写邮箱和应用密码"
    }

    func clear() {
        username = ""
        appPassword = ""
        hasPassword = false
        lastSyncAt = nil
        lastMessage = "已清除坚果云配置"
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.removeObject(forKey: passKey)
    }

    @discardableResult
    func testConnection() async -> Bool {
        guard isConfigured else {
            lastMessage = "请先填写邮箱和应用密码"
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            // PROPFIND 根目录，验证账号/应用密码
            var req = URLRequest(url: Self.baseURL)
            req.httpMethod = "PROPFIND"
            req.setValue("1", forHTTPHeaderField: "Depth")
            req.httpBody = Data(#"<?xml version="1.0"?><propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>"#.utf8)
            let (_, http) = try await webdav(req)
            if (200..<300).contains(http.statusCode) {
                lastMessage = "连接成功"
                return true
            }
            if http.statusCode == 401 {
                lastMessage = "认证失败：请用坚果云「应用密码」，不是登录密码"
                return false
            }
            lastMessage = "连接失败 HTTP \(http.statusCode)"
            return false
        } catch {
            lastMessage = "连接失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 读云端快照；404 视为还没有文件。
    func fetchData() async throws -> Data? {
        var req = URLRequest(url: remoteFileURL)
        req.httpMethod = "GET"
        let (data, http) = try await webdav(req)
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func putData(_ data: Data) async throws {
        try await ensureFolder()
        var req = URLRequest(url: remoteFileURL)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (_, http) = try await webdav(req)
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func ensureFolder() async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(Self.folderName))
        req.httpMethod = "MKCOL"
        let (_, http) = try await webdav(req)
        // 201 新建 / 405 已存在 / 301 等均可继续 PUT
        if http.statusCode == 401 {
            throw URLError(.userAuthenticationRequired)
        }
    }

    private func webdav(_ base: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = base
        req.timeoutInterval = 25
        req.setValue("CamWeb/1.3", forHTTPHeaderField: "User-Agent")
        let token = Data("\(username):\(appPassword)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// 坚果云上的三份名单快照。
struct NutstoreSnapshot: Codable, Equatable {
    var version: Int
    var updatedAt: TimeInterval
    var following: CloudSyncedMap
    var special: CloudSyncedMap
    var tags: CloudSyncedMap

    static let empty = NutstoreSnapshot(
        version: 1,
        updatedAt: 0,
        following: .empty,
        special: .empty,
        tags: .empty
    )
}

/// 拉坚果云 → 与本地并集合并 → 写回。证书不同时用这条通道互通。
@MainActor
enum NutstoreSyncCoordinator {
    private static var inFlight = false

    @discardableResult
    static func syncAll(showMessage: Bool = true) async -> Bool {
        let nutstore = NutstoreSession.shared
        guard nutstore.isConfigured else {
            if showMessage { nutstore.setMessage("未配置坚果云，请到设置填写") }
            return false
        }
        guard !inFlight else { return false }
        inFlight = true
        nutstore.markBusy(true)
        defer {
            inFlight = false
            nutstore.markBusy(false)
        }

        // 顺带刷一次 iCloud KVS（同证书时仍可同步）
        _ = FollowingStore.shared.syncNow()
        _ = SpecialFollowStore.shared.syncNow()
        _ = FavoriteTagsStore.shared.syncNow()

        var remote = NutstoreSnapshot.empty
        do {
            if let data = try await nutstore.fetchData() {
                remote = (try? JSONDecoder().decode(NutstoreSnapshot.self, from: data)) ?? .empty
            }
        } catch {
            if showMessage {
                nutstore.setMessage("拉取失败：\(error.localizedDescription)")
            }
            return false
        }

        FollowingStore.shared.applyCloudSnapshot(remote.following)
        SpecialFollowStore.shared.applyCloudSnapshot(remote.special)
        FavoriteTagsStore.shared.applyCloudSnapshot(remote.tags)

        let merged = NutstoreSnapshot(
            version: 1,
            updatedAt: Date().timeIntervalSince1970,
            following: FollowingStore.shared.cloudSnapshot,
            special: SpecialFollowStore.shared.cloudSnapshot,
            tags: FavoriteTagsStore.shared.cloudSnapshot
        )

        do {
            let data = try JSONEncoder().encode(merged)
            try await nutstore.putData(data)
            nutstore.markSynced()
            if showMessage { nutstore.setMessage("已与坚果云合并同步") }
            return true
        } catch {
            if showMessage {
                nutstore.setMessage("上传失败：\(error.localizedDescription)")
            }
            return false
        }
    }
}
