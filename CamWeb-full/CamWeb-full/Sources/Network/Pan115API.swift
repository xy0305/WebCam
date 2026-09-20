import Foundation

/// 网盘走 OpenList：列表 `/api/fs/list`，播放 `/api/fs/get` 的 raw_url（115 由 OpenList 302）。
enum Pan115API {
    static let userAgent = "Mozilla/5.0 115disk/30.1.0"
    static let playUA = userAgent
    static let origin = "https://115.com"

    private static let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    struct UserInfo {
        let id: String
        let name: String
    }

    struct Node: Identifiable, Hashable {
        let id: String
        let name: String
        let isDir: Bool
        let size: Int64
        let pickCode: String
        var path: String { id }
    }

    struct InitUpload {
        var rapid: Bool
        var fileID: String?
        var host: String
        var object: String
        var accessKeyId: String
        var accessKeySecret: String
        var securityToken: String
        var callback: String
        var callbackVar: String
        var bucket: String
        var endpoint: String
        var formPolicy: String
        var formSignature: String
        var useForm: Bool
    }

    enum APIError: LocalizedError {
        case needLogin
        case badResponse
        case httpStatus(Int)
        case message(String)
        var errorDescription: String? {
            switch self {
            case .needLogin: return "请先登录 OpenList"
            case .badResponse: return "OpenList 接口返回异常"
            case .httpStatus(let n): return "OpenList HTTP \(n)"
            case .message(let s): return s
            }
        }
    }

    static func login(username: String, password: String) async throws -> String {
        let obj = try await post("/api/auth/login", body: [
            "username": username,
            "password": password
        ], auth: false)
        guard let data = obj["data"] as? [String: Any],
              let token = string(data["token"]), !token.isEmpty else {
            throw APIError.message(string(obj["message"]) ?? "登录失败")
        }
        return token
    }

    static func userInfo() async throws -> UserInfo {
        let obj = try await get("/api/me")
        let data = obj["data"] as? [String: Any] ?? obj
        let name = string(data["username"]) ?? string(data["Username"]) ?? "OpenList"
        let id = string(data["id"]) ?? name
        return UserInfo(id: id, name: name)
    }

    static func list(cid: String, offset: Int = 0, limit: Int = 0) async throws -> [Node] {
        let path = normalize(cid)
        let obj = try await post("/api/fs/list", body: [
            "path": path,
            "password": "",
            "page": 1,
            "per_page": 0,
            "refresh": false
        ])
        let data = obj["data"] as? [String: Any] ?? [:]
        let rows = data["content"] as? [[String: Any]] ?? []
        return rows.compactMap { parseNode($0, dir: path) }
    }

    static func listAll(cid: String) async throws -> [Node] {
        try await list(cid: cid)
    }

    static func search(keyword: String, cid: String = "/115", foldersOnly: Bool = true) async throws -> [Node] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { return [] }
        let obj = try await post("/api/fs/search", body: [
            "parent": normalize(cid),
            "keywords": q,
            "scope": foldersOnly ? 1 : 0,
            "page": 1,
            "per_page": 100
        ])
        let data = obj["data"] as? [String: Any] ?? obj
        let rows = data["content"] as? [[String: Any]] ?? []
        return rows.compactMap { item in
            let parent = string(item["parent"]) ?? "/"
            let name = string(item["name"]) ?? ""
            guard !name.isEmpty else { return nil }
            let isDir = item["is_dir"] as? Bool ?? false
            if foldersOnly && !isDir { return nil }
            let path = join(parent, name)
            return Node(
                id: path,
                name: name,
                isDir: isDir,
                size: int64(item["size"]),
                pickCode: path
            )
        }
    }

    static func ensureFolder(parent: String, parts: [String]) async throws -> String {
        var cid = normalize(parent)
        for raw in parts {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "." else { continue }
            let kids = try await listAll(cid: cid)
            if let hit = kids.first(where: { $0.isDir && $0.name == name }) {
                cid = hit.id
                continue
            }
            cid = try await mkdir(parent: cid, name: name)
        }
        return cid
    }

    static func delete(id: String, pid: String? = nil) async throws {
        let path = normalize(id)
        let dir = pid.map(normalize) ?? parent(path)
        let name = basename(path)
        _ = try await post("/api/fs/remove", body: [
            "dir": dir,
            "names": [name]
        ])
    }

    static func mkdir(parent: String, name: String) async throws -> String {
        let path = join(parent, name)
        _ = try await post("/api/fs/mkdir", body: ["path": path])
        return path
    }

    static func rename(id: String, name: String) async throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw APIError.message("名称无效") }
        _ = try await post("/api/fs/rename", body: [
            "path": normalize(id),
            "name": n
        ])
    }

    static func move(ids: [String], to destCID: String) async throws {
        try await relocate(ids, to: destCID, copy: false)
    }

    static func copy(ids: [String], to destCID: String) async throws {
        try await relocate(ids, to: destCID, copy: true)
    }

    private static func relocate(_ ids: [String], to dest: String, copy: Bool) async throws {
        guard let first = ids.first else { return }
        let srcDir = parent(first)
        let names = ids.map(basename)
        _ = try await post(copy ? "/api/fs/copy" : "/api/fs/move", body: [
            "src_dir": srcDir,
            "dst_dir": normalize(dest),
            "names": names
        ])
    }

    struct SpaceInfo {
        var used: Int64 = 0
        var total: Int64 = 0
        var text: String { "" }
    }

    static func spaceInfo() async throws -> SpaceInfo { SpaceInfo() }

    struct OfflineTask: Identifiable, Hashable {
        let id: String
        let name: String
        let infoHash: String
        let url: String
        let status: Int
        let size: Int64
        let percent: Double
        var statusText: String {
            switch status {
            case 0: return "等待"
            case 1: return "下载中"
            case 2: return "完成"
            case -1: return "失败"
            default: return "未知"
            }
        }
    }

    static func addOffline(urls: [String], dirID: String) async throws -> String {
        _ = try await post("/api/fs/add_offline_download", body: [
            "urls": urls,
            "path": normalize(dirID),
            "tool": "115",
            "delete_policy": "delete_on_upload_succeed"
        ])
        return "已提交到 OpenList"
    }

    static func listOffline(page: Int = 1) async throws -> (tasks: [OfflineTask], quota: Int64, pageCount: Int) {
        ([], 0, 1)
    }

    static func deleteOffline(hashes: [String], deleteFiles: Bool) async throws {}
    static func clearOffline(flag: Int) async throws {}

    struct RecycleItem: Identifiable, Hashable {
        let id: String
        let name: String
        let size: Int64
        let isDir: Bool
    }

    static func recycleList() async throws -> [RecycleItem] { [] }
    static func recycleRevert(ids: [String]) async throws {
        throw APIError.message("回收站请在 OpenList 网页操作")
    }
    static func recycleClean() async throws {
        throw APIError.message("回收站请在 OpenList 网页操作")
    }

    static func parseShare(_ raw: String) -> (code: String, receive: String) {
        (raw, "")
    }

    static func shareSnap(code: String, receive: String, cid: String = "/") async throws -> [Node] {
        throw APIError.message("分享请在 OpenList 网页操作")
    }

    static func shareReceive(code: String, receive: String, fileIDs: [String], destCID: String) async throws {
        throw APIError.message("分享请在 OpenList 网页操作")
    }

    static func sha1Hex(_ data: Data) -> String { "" }
    static func fileSHA1(url: URL) throws -> (full: String, head: String) { ("", "") }

    static func initUpload(fileName: String, size: Int64, sha1: String, preSha1: String, dirID: String) async throws -> InitUpload {
        throw APIError.message("请走 OpenList 上传")
    }

    /// 把 115 Cookie 挂到本机 Alist。已有 `/115` 则跳过。
    static func ensure115Storage(cookie: String) async throws {
        let raw = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if let list = try? await get("/api/admin/storage/list") {
            let data = list["data"] as? [String: Any] ?? [:]
            let rows = data["content"] as? [[String: Any]] ?? []
            if rows.contains(where: { string($0["mount_path"]) == "/115" || string($0["driver"]) == "115 Cloud" }) {
                return
            }
        }
        let addition: [String: Any] = [
            "cookie": raw,
            "qrcode_token": "",
            "qrcode_source": "linux",
            "page_size": 1000,
            "limit_rate": 2,
            "root_folder_id": "0"
        ]
        let additionJSON = try JSONSerialization.data(withJSONObject: addition)
        let additionText = String(data: additionJSON, encoding: .utf8) ?? "{}"
        _ = try await post("/api/admin/storage/create", body: [
            "mount_path": "/115",
            "order": 0,
            "driver": "115 Cloud",
            "cache_expiration": 30,
            "status": "work",
            "addition": additionText,
            "remark": "CamWeb",
            "disabled": false,
            "web_proxy": false,
            "webdav_policy": "302_redirect",
            "proxy_range": false,
            "down_proxy_url": ""
        ])
    }

    static func playHeaders() -> [String: String] { fileHeaders() }

    static func fileHeaders() -> [String: String] {
        ["User-Agent": playUA, "Accept": "*/*"]
    }

    static func cdnHeaders() -> [String: String] { fileHeaders() }

    static func downloadURL(pickCode: String) async throws -> URL {
        try await fileLink(pickCode: pickCode).url
    }

    static func fileLink(pickCode: String) async throws -> (url: URL, headers: [String: String]) {
        let path = normalize(pickCode)
        let obj = try await post("/api/fs/get", body: [
            "path": path,
            "password": ""
        ], extraHeaders: ["User-Agent": playUA])
        let data = obj["data"] as? [String: Any] ?? [:]
        guard let raw = string(data["raw_url"]), let url = URL(string: raw) else {
            throw APIError.message("OpenList 没有返回播放地址")
        }
        return (url, fileHeaders())
    }

    static func playURL(pickCode: String, filename: String = "") async throws -> URL {
        try await playSource(pickCode: pickCode, filename: filename).url
    }

    static func playSource(pickCode: String, filename: String = "") async throws -> (url: URL, ffmpeg: Bool) {
        let url = try await downloadURL(pickCode: pickCode)
        return (url, true)
    }

    static func putFile(path: String, fileURL: URL) -> URLRequest {
        let dest = normalize(path)
        let encoded = dest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dest
        var req = URLRequest(url: endpoint("/api/fs/put"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 60 * 60 * 12
        req.setValue(authToken, forHTTPHeaderField: "Authorization")
        req.setValue(encoded, forHTTPHeaderField: "File-Path")
        req.setValue("true", forHTTPHeaderField: "Overwrite")
        req.setValue("false", forHTTPHeaderField: "As-Task")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(playUA, forHTTPHeaderField: "User-Agent")
        return req
    }

    static func isPlayable(_ name: String) -> Bool {
        [
            "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm",
            "ts", "m2ts", "mts", "m3u8", "iso", "mpg", "mpeg", "vob",
            "rm", "rmvb", "f4v", "asf", "3gp", "tp", "trp", "dat"
        ].contains(fileExt(name))
    }

    static func needsFFmpeg(_ name: String) -> Bool { isPlayable(name) }

    static func isImage(_ name: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif"].contains(fileExt(name))
    }

    static func fileExt(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p == "0" { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func join(_ dir: String, _ name: String) -> String {
        let d = normalize(dir)
        if d == "/" { return "/\(name)" }
        return d + "/" + name
    }

    static func parent(_ path: String) -> String {
        let p = normalize(path)
        guard p != "/" else { return "/" }
        let url = URL(fileURLWithPath: p)
        let up = url.deletingLastPathComponent().path
        return normalize(up)
    }

    static func basename(_ path: String) -> String {
        URL(fileURLWithPath: normalize(path)).lastPathComponent
    }

    private static func parseNode(_ item: [String: Any], dir: String) -> Node? {
        let name = string(item["name"]) ?? ""
        guard !name.isEmpty else { return nil }
        let isDir = item["is_dir"] as? Bool ?? false
        let path = join(dir, name)
        return Node(id: path, name: name, isDir: isDir, size: int64(item["size"]), pickCode: path)
    }

    private static var authToken: String? { Pan115Session.shared.token }

    private static func endpoint(_ path: String) -> URL {
        var base = Pan115Session.shared.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? URL(string: "https://invalid.local")!
    }

    private static func get(_ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint(path))
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        applyAuth(&req)
        return try await send(req)
    }

    private static func post(_ path: String, body: [String: Any], auth: Bool = true, extraHeaders: [String: String] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if auth { applyAuth(&req) }
        extraHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func applyAuth(_ req: inout URLRequest) {
        if let token = authToken, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "Authorization")
        }
        req.setValue(playUA, forHTTPHeaderField: "User-Agent")
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        if Pan115Session.shared.baseURL.isEmpty { throw APIError.needLogin }
        let (data, response) = try await http.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw APIError.needLogin }
            if !(200..<300).contains(http.statusCode) {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msg = string(obj["message"]) {
                    throw APIError.message(msg)
                }
                throw APIError.httpStatus(http.statusCode)
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        if let code = obj["code"] as? Int, code != 200 {
            throw APIError.message(string(obj["message"]) ?? "OpenList 错误 \(code)")
        }
        return obj
    }

    private static func string(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let n = any as? Int { return String(n) }
        return nil
    }

    private static func int64(_ any: Any?) -> Int64 {
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let n = Int64(s) { return n }
        return 0
    }
}
