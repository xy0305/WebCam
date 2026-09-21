import CryptoKit
import Foundation

/// 网盘走 OpenList：列表 `/api/fs/list`，播放 `/api/fs/get` 的 raw_url（115 由 OpenList 302）。
enum Pan115API {
    /// OpenList `DownloadWithUA`：换链和播放必须同一 UA。Safari 换的 CDN 能 200；115disk 会 403。
    static let playUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let userAgent = playUA
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

    static let clientID = AlistEmbedded.clientID

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
        var id: String { infoHash.isEmpty ? "\(name)-\(url)" : infoHash }
        let infoHash: String
        let name: String
        let size: Int64
        let url: String
        let status: Int
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

    /// 对照 AVDB：内嵌 Alist 没有 tool 115，离线走 115 网页 lixian。
    static func addOffline(urls: [String], dirID: String) async throws -> String {
        let links = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !links.isEmpty else { throw APIError.message("链接为空") }
        guard cookieHeader != nil else { throw APIError.needLogin }
        let cid = offlineCID(dirID)
        let uid = cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        var sign = ""
        var time = "\(Int(Date().timeIntervalSince1970 * 1000))"
        if let s = try? await offlineSign() {
            sign = s.sign
            time = s.time
        }
        if links.count == 1 {
            var fields = ["url": links[0], "wp_path_id": cid]
            if !uid.isEmpty { fields["uid"] = uid }
            if !sign.isEmpty { fields["sign"] = sign; fields["time"] = time }
            return try parseOfflineAdd(try await pan115Form(URL(string: "https://115.com/web/lixian/?ct=lixian&ac=add_task_url")!, fields))
        }
        var fields = ["wp_path_id": cid]
        if !uid.isEmpty { fields["uid"] = uid }
        if !sign.isEmpty { fields["sign"] = sign; fields["time"] = time }
        for (i, link) in links.enumerated() { fields["url[\(i)]"] = link }
        return try parseOfflineAdd(try await pan115Form(URL(string: "https://115.com/web/lixian/?ct=lixian&ac=add_task_urls")!, fields))
    }

    static func listOffline(page: Int = 1) async throws -> (tasks: [OfflineTask], quota: Int64, pageCount: Int) {
        guard cookieHeader != nil else { throw APIError.needLogin }
        let urls = [
            "https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=\(page)",
            "https://lixian.115.com/lixian/?ct=lixian&ac=task_lists&page=\(page)"
        ]
        var last: Error = APIError.badResponse
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            do {
                let obj = try await pan115Form(url, ["page": "\(page)"])
                if let state = obj["state"] as? Bool, state == false {
                    last = APIError.message(string(obj["error"]) ?? string(obj["error_msg"]) ?? "离线列表失败")
                    continue
                }
                let rawTasks = (obj["tasks"] as? [[String: Any]])
                    ?? ((obj["data"] as? [String: Any])?["tasks"] as? [[String: Any]])
                    ?? []
                let tasks = rawTasks.map { item in
                    OfflineTask(
                        infoHash: string(item["info_hash"] ?? item["hash"]) ?? "",
                        name: string(item["name"]) ?? "",
                        size: int64(item["size"]),
                        url: string(item["url"]) ?? "",
                        status: Int(string(item["status"]) ?? "0") ?? 0,
                        percent: Double(string(item["percentDone"] ?? item["percent"]) ?? "0") ?? 0
                    )
                }
                let quota = int64(obj["quota"])
                let pages = Int(string(obj["page_count"]) ?? "1") ?? 1
                return (tasks, quota, pages)
            } catch {
                last = error
            }
        }
        throw last
    }

    static func deleteOffline(hashes: [String], deleteFiles: Bool) async throws {
        let hs = hashes.filter { !$0.isEmpty }
        guard !hs.isEmpty else { return }
        var fields = ["flag": deleteFiles ? "1" : "0"]
        for (i, h) in hs.enumerated() { fields["hash[\(i)]"] = h }
        fields["hash"] = hs[0]
        let urls = [
            "https://115.com/web/lixian/?ct=lixian&ac=task_del",
            "https://lixian.115.com/lixian/?ct=lixian&ac=task_del"
        ]
        var last: Error = APIError.badResponse
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            do {
                let obj = try await pan115Form(url, fields)
                if pan115OK(obj) { return }
                last = APIError.message(string(obj["error"]) ?? string(obj["error_msg"]) ?? "删除离线任务失败")
            } catch {
                last = error
            }
        }
        throw last
    }

    static func clearOffline(flag: Int) async throws {
        let obj = try await pan115Form(URL(string: "https://115.com/web/lixian/?ct=lixian&ac=task_clear")!, [
            "flag": "\(flag)"
        ])
        guard pan115OK(obj) else {
            throw APIError.message(string(obj["error"]) ?? "清空失败")
        }
    }

    private static func offlineSign() async throws -> (sign: String, time: String) {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let obj = try await pan115JSON(URL(string: "https://115.com/?ct=offline&ac=space&_=\(ts)")!)
        guard let sign = string(obj["sign"]), !sign.isEmpty else {
            throw APIError.message("获取离线签名失败")
        }
        return (sign, string(obj["time"]) ?? "\(ts)")
    }

    private static func parseOfflineAdd(_ obj: [String: Any]) throws -> String {
        if pan115OK(obj) { return "已加入离线任务" }
        let msg = string(obj["error_msg"]) ?? string(obj["error"]) ?? string(obj["msg"]) ?? ""
        let code = Int(string(obj["errcode"] ?? obj["errno"]) ?? "0") ?? 0
        if code == 10008 || msg.contains("已存在") || msg.contains("重复") {
            return "任务已存在"
        }
        throw APIError.message(msg.isEmpty ? "添加离线任务失败" : msg)
    }

    private static func offlineCID(_ dirID: String) -> String {
        let p = dirID.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p.hasPrefix("/") { return cookieValue("CID") ?? "0" }
        return p
    }

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

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    static func fileSHA1(url: URL) throws -> (full: String, head: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        var head = Data()
        while true {
            let chunk = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            if head.count < 128 * 1024 {
                let need = 128 * 1024 - head.count
                head.append(chunk.prefix(need))
            }
        }
        let full = hasher.finalize().map { String(format: "%02X", $0) }.joined()
        return (full, sha1Hex(head))
    }

    /// 对照 build 43：秒传 / sampleinitupload OSS，dirID 必须是 115 cid。
    static func initUpload(fileName: String, size: Int64, sha1: String, preSha1: String, dirID: String) async throws -> InitUpload {
        let cid = driveCID(dirID)
        if let sample = try? await sampleInit(fileName: fileName, size: size, dirID: cid) {
            return sample
        }
        return try await simpleInit(fileName: fileName, size: size, sha1: sha1, dirID: cid)
    }

    private static func sampleInit(fileName: String, size: Int64, dirID: String) async throws -> InitUpload {
        let uid = cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        let obj = try await pan115Form(URL(string: "https://uplb.115.com/3.0/sampleinitupload.php")!, [
            "userid": uid,
            "filename": fileName,
            "filesize": "\(size)",
            "target": "U_1_\(dirID)"
        ])
        if let err = string(obj["error"]), !err.isEmpty { throw APIError.message(err) }
        let host = string(obj["host"]) ?? string(obj["endpoint"]) ?? ""
        let object = string(obj["object"]) ?? string(obj["key"]) ?? ""
        guard !host.isEmpty, !object.isEmpty else { throw APIError.badResponse }
        return InitUpload(
            rapid: false, fileID: nil, host: host, object: object,
            accessKeyId: string(obj["accessid"]) ?? string(obj["OSSAccessKeyId"]) ?? "",
            accessKeySecret: "", securityToken: string(obj["token"]) ?? "",
            callback: string(obj["callback"]) ?? "", callbackVar: string(obj["callback_var"]) ?? "",
            bucket: string(obj["bucket"]) ?? "", endpoint: host,
            formPolicy: string(obj["policy"]) ?? "", formSignature: string(obj["signature"]) ?? "",
            useForm: true
        )
    }

    private static func simpleInit(fileName: String, size: Int64, sha1: String, dirID: String) async throws -> InitUpload {
        let uid = cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        let obj = try await pan115Form(URL(string: "https://uplb.115.com/3.0/initupload.php")!, [
            "appid": "0",
            "appversion": "27.0.5.7",
            "userid": uid,
            "filename": fileName,
            "filesize": "\(size)",
            "fileid": sha1,
            "target": "U_1_\(dirID)"
        ])
        let status = (obj["status"] as? Int) ?? Int(string(obj["status"]) ?? "-1") ?? -1
        if status == 1 || (string(obj["statuscode"]) == "0" && obj["pickcode"] != nil) {
            return InitUpload(
                rapid: true, fileID: string(obj["file_id"]) ?? string(obj["fileid"]),
                host: "", object: "", accessKeyId: "", accessKeySecret: "", securityToken: "",
                callback: "", callbackVar: "", bucket: "", endpoint: "", formPolicy: "", formSignature: "", useForm: false
            )
        }
        let host = string(obj["host"]) ?? ""
        let object = string(obj["object"]) ?? ""
        guard !object.isEmpty else {
            throw APIError.message(string(obj["message"]) ?? string(obj["error"]) ?? "初始化上传失败，请确认 Cookie 有效")
        }
        return InitUpload(
            rapid: false, fileID: sha1, host: host, object: object,
            accessKeyId: string(obj["accessid"]) ?? "",
            accessKeySecret: string(obj["accesskey_secret"]) ?? "",
            securityToken: string(obj["token"]) ?? "",
            callback: string(obj["callback"]) ?? "", callbackVar: string(obj["callback_var"]) ?? "",
            bucket: string(obj["bucket"]) ?? "", endpoint: host,
            formPolicy: string(obj["policy"]) ?? "", formSignature: string(obj["signature"]) ?? "",
            useForm: !(string(obj["policy"]) ?? "").isEmpty
        )
    }

    /// 备份/上传选目录：走 115 网页 files API，返回数字 cid。
    static func driveList(cid: String) async throws -> [Node] {
        let id = driveCID(cid)
        let query = "aid=1&cid=\(encodeForm(id))&o=user_ptime&asc=0&offset=0&show_dir=1&limit=1150&natsort=1&format=json"
        let urls = [
            "https://aps.115.com/natsort/files.php?\(query)",
            "https://webapi.115.com/files?\(query)"
        ]
        var last: Error = APIError.badResponse
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            do {
                let obj = try await pan115JSON(url)
                if let state = obj["state"] as? Bool, state == false {
                    last = APIError.message(string(obj["error"]) ?? "列出目录失败")
                    continue
                }
                let rows = (obj["data"] as? [[String: Any]]) ?? (obj["list"] as? [[String: Any]]) ?? []
                return rows.compactMap(parseDriveNode)
            } catch {
                last = error
            }
        }
        throw last
    }

    static func driveSearch(keyword: String) async throws -> [Node] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { return [] }
        var c = URLComponents(string: "https://webapi.115.com/files/search")!
        c.queryItems = [
            URLQueryItem(name: "search_value", value: q),
            URLQueryItem(name: "aid", value: "1"),
            URLQueryItem(name: "cid", value: "0"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "115"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "search_file", value: "2")
        ]
        let obj = try await pan115JSON(c.url!)
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "搜索失败")
        }
        let rows = (obj["data"] as? [[String: Any]]) ?? []
        return rows.compactMap(parseDriveNode).filter(\.isDir)
    }

    static func driveEnsureFolder(parent: String, parts: [String]) async throws -> String {
        var cid = driveCID(parent)
        for raw in parts {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "." else { continue }
            let kids = try await driveList(cid: cid)
            if let hit = kids.first(where: { $0.isDir && $0.name == name }) {
                cid = hit.id
                continue
            }
            cid = try await driveMkdir(parent: cid, name: name)
        }
        return cid
    }

    static func driveMkdir(parent: String, name: String) async throws -> String {
        let obj = try await pan115Form(URL(string: "https://webapi.115.com/files/add")!, [
            "pid": driveCID(parent),
            "cname": name
        ])
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "新建文件夹失败")
        }
        return string(obj["cid"]) ?? parent
    }

    private static func parseDriveNode(_ item: [String: Any]) -> Node? {
        let fid = string(item["fid"] ?? item["file_id"]) ?? ""
        let dirID = string(item["cid"] ?? item["pid"]) ?? ""
        let pc = string(item["pc"] ?? item["pick_code"] ?? item["pickcode"]) ?? ""
        let fc = string(item["fc"] ?? item["file_category"]) ?? ""
        let sha = string(item["sha"] ?? item["sha1"]) ?? ""
        let isDir: Bool
        if fc == "0" {
            isDir = true
        } else if fc == "1" || !pc.isEmpty || !sha.isEmpty || !fid.isEmpty {
            isDir = false
        } else {
            isDir = true
        }
        let id = isDir ? (dirID.isEmpty ? fid : dirID) : (fid.isEmpty ? pc : fid)
        guard !id.isEmpty else { return nil }
        return Node(
            id: id,
            name: string(item["n"] ?? item["fn"] ?? item["file_name"] ?? item["name"]) ?? id,
            isDir: isDir,
            size: int64(item["s"] ?? item["file_size"] ?? item["fs"] ?? item["size"]),
            pickCode: pc
        )
    }

    static func driveDelete(id: String) async throws {
        let obj = try await pan115Form(URL(string: "https://webapi.115.com/rb/delete")!, [
            "fid[0]": id,
            "ignore_warn": "1"
        ])
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "删除失败")
        }
    }

    /// 115 直连换下载链。同步快照用它，不吃 Alist 的 meta 缓存，也不依赖 /115 挂载是否存在。
    static func driveDownloadURL(pickCode: String) async throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "https://webapi.115.com/files/download?pickcode=\(encodeForm(pickCode))&_=\(stamp)")!
        let obj = try await pan115JSON(url)
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error_msg"]) ?? string(obj["error"]) ?? "115 没有返回下载地址")
        }
        guard let raw = string(obj["file_url"]), raw.hasPrefix("http"), let link = URL(string: raw) else {
            throw APIError.message("115 下载地址格式不认识")
        }
        return link
    }

    static func driveData(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 40
        pan115Headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw APIError.badResponse }
        return data
    }

    static func driveCID(_ raw: String) -> String {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p == "/" || p == "/115" || p.hasPrefix("/") { return "0" }
        return p
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
        // 对照 OpenList 网页：播 /d/path，由 Alist 用播放器 UA 换链再 302。
        if let url = downURL(path: path, sign: string(data["sign"])) {
            return (url, playHeaders())
        }
        if let raw = string(data["raw_url"]), let url = URL(string: raw) {
            return (url, playHeaders())
        }
        throw APIError.message("OpenList 没有返回播放地址")
    }

    private static func downURL(path: String, sign: String?) -> URL? {
        var base = Pan115Session.shared.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let encoded = encodePath(path)
        var text = base + "/d" + encoded
        if let sign, !sign.isEmpty {
            let q = sign.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sign
            text += "?sign=" + q
        }
        return URL(string: text)
    }

    private static func encodePath(_ path: String) -> String {
        let p = normalize(path)
        if p == "/" { return "/" }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return "/" + p.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0)
        }.joined(separator: "/")
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
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        return req
    }

    /// 旧版 115 fid `0` / 根路径都挂到 `/115`。
    static func drivePath(_ path: String) -> String {
        let p = normalize(path)
        return p == "/" ? "/115" : p
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
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        req.setValue(playUA, forHTTPHeaderField: "User-Agent")
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
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        if Pan115Session.shared.baseURL.isEmpty { throw APIError.needLogin }
        return try await sendOnce(req, retried: false)
    }

    private static func sendOnce(_ req: URLRequest, retried: Bool) async throws -> [String: Any] {
        let (data, response) = try await http.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || isInvalidToken(data) {
                if !retried, canRelogin(req) {
                    await AlistEmbedded.shared.loginAdmin()
                    var again = req
                    applyAuth(&again)
                    return try await sendOnce(again, retried: true)
                }
                throw APIError.needLogin
            }
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
            let msg = string(obj["message"]) ?? "OpenList 错误 \(code)"
            if !retried, canRelogin(req), isInvalidTokenMessage(msg) {
                await AlistEmbedded.shared.loginAdmin()
                var again = req
                applyAuth(&again)
                return try await sendOnce(again, retried: true)
            }
            throw APIError.message(msg)
        }
        return obj
    }

    private static func isInvalidToken(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return isInvalidTokenMessage(string(obj["message"]) ?? "")
    }

    private static func canRelogin(_ req: URLRequest) -> Bool {
        !(req.url?.path.contains("/api/auth/login") ?? false)
    }

    private static func isInvalidTokenMessage(_ msg: String) -> Bool {
        let m = msg.lowercased()
        return m.contains("token is invalidated") || m.contains("token is expired") || m.contains("session inactive")
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

    private static var cookieHeader: String? { Pan115Session.shared.cookieHeader }

    static func cookieValue(_ name: String) -> String? {
        guard let header = cookieHeader else { return nil }
        for part in header.split(separator: ";") {
            let bits = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if bits.count == 2, bits[0].caseInsensitiveCompare(name) == .orderedSame { return bits[1] }
        }
        return nil
    }

    private static func pan115Headers() -> [String: String] {
        var h = [
            "User-Agent": playUA,
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://115.com/",
            "Origin": origin
        ]
        if let cookie = cookieHeader { h["Cookie"] = cookie }
        return h
    }

    private static func pan115JSON(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        pan115Headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpStatus(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.badResponse }
        return obj
    }

    private static func pan115Form(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        pan115Headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map {
            "\(encodeForm($0.key))=\(encodeForm($0.value))"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpStatus(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.badResponse }
        return obj
    }

    private static func encodeForm(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    private static func pan115OK(_ obj: [String: Any]) -> Bool {
        if let b = obj["state"] as? Bool { return b }
        if let n = obj["state"] as? Int { return n == 1 }
        if let s = obj["state"] as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }
}
