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

    var remoteFileURL: URL { Self.fileURL }

    static var folderURL: URL {
        baseURL.appendingPathComponent(folderName, isDirectory: true)
    }

    static var fileURL: URL {
        folderURL.appendingPathComponent(fileName)
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

    /// 读云端快照；不存在/父目录未建时视为还没有文件（404/405/409/410/403）。
    func fetchData() async throws -> Data? {
        try await ensureFolder()
        var req = URLRequest(url: remoteFileURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await webdav(req)
        let code = http.statusCode
        if (200..<300).contains(code), !data.isEmpty {
            return data
        }
        // 空文件 / 尚未创建 / 父目录冲突：都当作无云端快照
        if code == 204 || code == 404 || code == 405 || code == 409 || code == 410 || code == 403 {
            return nil
        }
        if code == 401 {
            throw NutstoreWebDAVError.unauthorized
        }
        if (200..<300).contains(code) {
            return nil
        }
        throw NutstoreWebDAVError.badStatus(code, data: data)
    }

    func putData(_ data: Data) async throws {
        try await ensureFolder()
        var req = URLRequest(url: remoteFileURL)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (respData, http) = try await webdav(req)
        let code = http.statusCode
        if (200..<300).contains(code) { return }
        if code == 401 { throw NutstoreWebDAVError.unauthorized }
        // 父目录不存在时再建一次并重试
        if code == 409 {
            try await ensureFolder(force: true)
            let retry = try await webdav(req)
            if (200..<300).contains(retry.1.statusCode) { return }
            throw NutstoreWebDAVError.badStatus(retry.1.statusCode, data: retry.0)
        }
        throw NutstoreWebDAVError.badStatus(code, data: respData)
    }

    private func ensureFolder(force: Bool = false) async throws {
        var req = URLRequest(url: Self.folderURL)
        req.httpMethod = "MKCOL"
        let (_, http) = try await webdav(req)
        let code = http.statusCode
        // 201 新建 / 200·405 已存在 / 301 重定向，均可继续
        if code == 401 { throw NutstoreWebDAVError.unauthorized }
        if force, code >= 400, code != 405, code != 301 {
            throw NutstoreWebDAVError.badStatus(code, data: Data())
        }
    }

    private func webdav(_ base: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = base
        req.timeoutInterval = 25
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("CamWeb/1.3", forHTTPHeaderField: "User-Agent")
        let token = Data("\(username):\(appPassword)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw NutstoreWebDAVError.badStatus(-1, data: data)
            }
            return (data, http)
        } catch let error as NutstoreWebDAVError {
            throw error
        } catch let error as URLError {
            throw NutstoreWebDAVError.network(error.code.rawValue, error.localizedDescription)
        } catch {
            throw NutstoreWebDAVError.network(-1, error.localizedDescription)
        }
    }
}

enum NutstoreWebDAVError: LocalizedError {
    case unauthorized
    case badStatus(Int, data: Data)
    case network(Int, String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "认证失败（HTTP 401），请用坚果云「应用密码」"
        case .badStatus(let code, let data):
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty { return "服务器返回 HTTP \(code)" }
            return "服务器返回 HTTP \(code)：\(snippet)"
        case .network(let code, let message):
            return "网络错误 \(code)：\(message)"
        }
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
        var hadRemoteFile = false
        do {
            if let data = try await nutstore.fetchData() {
                hadRemoteFile = true
                remote = (try? JSONDecoder().decode(NutstoreSnapshot.self, from: data)) ?? .empty
            }
        } catch {
            // 认证/严重错误直接失败；其它拉取问题先按空云端继续上传，避免卡死首次同步
            if case NutstoreWebDAVError.unauthorized = error {
                if showMessage {
                    nutstore.setMessage("拉取失败：认证失败，请检查应用密码")
                }
                return false
            }
            if showMessage {
                nutstore.setMessage("云端暂无可用快照（\(error.localizedDescription)），将上传本机数据")
            }
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
            if showMessage {
                if hadRemoteFile {
                    nutstore.setMessage("已与坚果云合并同步")
                } else {
                    nutstore.setMessage("已上传本机数据到坚果云，另一台设备点「立即同步」即可合并")
                }
            }
            return true
        } catch {
            if showMessage {
                nutstore.setMessage("上传失败：\(error.localizedDescription)")
            }
            return false
        }
    }
}
