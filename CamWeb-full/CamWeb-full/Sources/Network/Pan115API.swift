import CryptoKit
import Foundation

enum Pan115API {
    static let userAgent = "Mozilla/5.0 115Browser/27.0.5.7"
    static let origin = "https://115.com"

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
            case .needLogin: return "115 Cookie 无效，请重新登录"
            case .badResponse: return "115 接口返回异常"
            case .httpStatus(let n): return "115 HTTP \(n)"
            case .message(let s): return s
            }
        }
    }

    static func userInfo() async throws -> UserInfo {
        let url = URL(string: "https://my.115.com/?ct=ajax&ac=nav")!
        let obj = try await json(url)
        if let err = obj["error"] as? String, !err.isEmpty { throw APIError.message(err) }
        let data = obj["data"] as? [String: Any] ?? obj
        let id = string(data["user_id"]) ?? string(data["uid"]) ?? cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        let name = string(data["user_name"]) ?? string(data["user_name"]) ?? string(obj["user_name"]) ?? "115"
        if id.isEmpty && name.isEmpty { throw APIError.needLogin }
        return UserInfo(id: id, name: name)
    }

    static func list(cid: String, offset: Int = 0, limit: Int = 1150) async throws -> [Node] {
        let query = "aid=1&cid=\(encode(cid))&o=user_ptime&asc=0&offset=\(offset)&show_dir=1&limit=\(limit)&natsort=1&format=json"
        let urls = [
            "https://aps.115.com/natsort/files.php?\(query)",
            "https://proapi.115.com/android/2.0/ufile/files?\(query)",
            "https://webapi.115.com/files?\(query)"
        ]
        var last: Error = APIError.badResponse
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            do {
                let obj = try await json(url)
                if let state = obj["state"] as? Bool, state == false {
                    last = APIError.message(string(obj["error"]) ?? "列出目录失败")
                    continue
                }
                let rows = extractRows(obj)
                let nodes = rows.compactMap(parseNode)
                if !nodes.isEmpty { return nodes }
                if obj["state"] as? Bool == true { return [] }
            } catch {
                last = error
            }
        }
        throw last
    }

    private static func extractRows(_ obj: [String: Any]) -> [[String: Any]] {
        func array(from value: Any?) -> [[String: Any]]? {
            if let arr = value as? [[String: Any]] { return arr }
            if let dict = value as? [String: Any] {
                for key in ["data", "list", "files", "items"] {
                    if let arr = dict[key] as? [[String: Any]] { return arr }
                }
            }
            return nil
        }
        return array(from: obj["data"]) ?? array(from: obj["list"]) ?? array(from: obj["files"]) ?? []
    }

    private static func parseNode(_ item: [String: Any]) -> Node? {
        let fid = string(item["fid"] ?? item["file_id"]) ?? ""
        let dirID = string(item["cid"] ?? item["pid"]) ?? ""
        let pc = string(item["pc"] ?? item["pick_code"] ?? item["pickcode"]) ?? ""
        let fc = string(item["fc"] ?? item["file_category"]) ?? ""
        let sha = string(item["sha"] ?? item["sha1"]) ?? ""
        // 115 文件 fid 常是 JSON 数字；以前只认 String，fid 空了就把文件当成文件夹，
        // 而且 id 全变成父目录 cid，ForEach 直接把文件挤掉。
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
            size: Int64(string(item["s"] ?? item["file_size"] ?? item["fs"] ?? item["size"]) ?? "0") ?? 0,
            pickCode: pc
        )
    }

    /// 全盘搜文件夹/文件。`search_file=2` 只搜目录；不传则文件+目录。
    static func search(keyword: String, cid: String = "0", foldersOnly: Bool = true) async throws -> [Node] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { return [] }
        var c = URLComponents(string: "https://webapi.115.com/files/search")!
        var items = [
            URLQueryItem(name: "search_value", value: q),
            URLQueryItem(name: "aid", value: "1"),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "115"),
            URLQueryItem(name: "format", value: "json")
        ]
        if foldersOnly {
            items.append(URLQueryItem(name: "search_file", value: "2"))
        }
        c.queryItems = items
        let obj = try await json(c.url!)
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "搜索失败")
        }
        let rows = extractRows(obj)
        return rows.compactMap(parseNode)
    }

    static func listAll(cid: String) async throws -> [Node] {
        var offset = 0
        var all: [Node] = []
        let pageSize = 1150
        for _ in 0..<40 {
            let page = try await list(cid: cid, offset: offset, limit: pageSize)
            all.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += page.count
        }
        return all
    }

    static func ensureFolder(parent: String, parts: [String]) async throws -> String {
        var cid = parent
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
        var fields = [
            "fid[0]": id,
            "ignore_warn": "1"
        ]
        if let pid, !pid.isEmpty { fields["pid"] = pid }
        let obj = try await form(URL(string: "https://webapi.115.com/rb/delete")!, fields)
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? string(obj["error_msg"]) ?? "删除失败")
        }
    }

    static func mkdir(parent: String, name: String) async throws -> String {
        let url = URL(string: "https://webapi.115.com/files/add")!
        let obj = try await form(url, [
            "pid": parent,
            "cname": name
        ])
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "新建文件夹失败")
        }
        return string(obj["cid"]) ?? parent
    }

    /// 对照 OpenList / 115driver：POST files/batch_rename
    static func rename(id: String, name: String) async throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !n.isEmpty else { throw APIError.message("名称无效") }
        let obj = try await form(URL(string: "https://webapi.115.com/files/batch_rename")!, [
            "fid": id,
            "file_name": n,
            "files_new_name[\(id)]": n
        ])
        guard ok(obj) else {
            throw APIError.message(string(obj["error"]) ?? string(obj["error_msg"]) ?? "重命名失败")
        }
    }

    /// 对照 OpenList：POST files/move，pid=目标，fid[N]=源
    static func move(ids: [String], to destCID: String) async throws {
        try await fileOp(URL(string: "https://webapi.115.com/files/move")!, ids: ids, destCID: destCID, fail: "移动失败")
    }

    /// 对照 OpenList：POST files/copy
    static func copy(ids: [String], to destCID: String) async throws {
        try await fileOp(URL(string: "https://webapi.115.com/files/copy")!, ids: ids, destCID: destCID, fail: "复制失败")
    }

    private static func fileOp(_ url: URL, ids: [String], destCID: String, fail: String) async throws {
        let fids = ids.filter { !$0.isEmpty }
        guard !fids.isEmpty else { throw APIError.message("没有可操作的文件") }
        var fields = ["pid": destCID]
        for (i, id) in fids.enumerated() { fields["fid[\(i)]"] = id }
        let obj = try await form(url, fields)
        guard ok(obj) else {
            throw APIError.message(string(obj["error"]) ?? string(obj["error_msg"]) ?? fail)
        }
    }

    struct SpaceInfo {
        let total: Int64
        let used: Int64
        var remain: Int64 { max(0, total - used) }
    }

    /// 对照 OpenList GetDetails：files/index_info
    static func spaceInfo() async throws -> SpaceInfo {
        let obj = try await json(URL(string: "https://webapi.115.com/files/index_info")!)
        let data = obj["data"] as? [String: Any] ?? obj
        let space = data["space_info"] as? [String: Any] ?? data
        func size(_ key: String) -> Int64 {
            if let nested = space[key] as? [String: Any] {
                return Int64(string(nested["size"]) ?? "0") ?? 0
            }
            return Int64(string(space[key]) ?? "0") ?? 0
        }
        let total = size("all_total")
        let used = size("all_use")
        if total > 0 || used > 0 { return SpaceInfo(total: total, used: used) }
        throw APIError.message(string(obj["error"]) ?? "拿不到空间信息")
    }

    struct OfflineTask: Identifiable, Hashable {
        var id: String { infoHash.isEmpty ? "\(name)-\(addTime)" : infoHash }
        let infoHash: String
        let name: String
        let size: Int64
        let url: String
        let status: Int
        let percent: Double
        let fileID: String
        let dirID: String
        let addTime: Int64

        var statusText: String {
            switch status {
            case 0: return "等待"
            case 1: return "下载中"
            case 2: return "完成"
            case -1: return "失败"
            default: return "未知 \(status)"
            }
        }
    }

    /// 对照 AVDB / OpenList：先 space 拿 sign，再 add_task_url。支持 magnet / ed2k / http。
    static func addOffline(urls: [String], dirID: String) async throws -> String {
        let links = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !links.isEmpty else { throw APIError.message("链接为空") }
        let uid = cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        var sign = ""
        var time = "\(Int(Date().timeIntervalSince1970 * 1000))"
        if let s = try? await offlineSign() {
            sign = s.sign
            time = s.time
        }
        if links.count == 1 {
            var fields = [
                "url": links[0],
                "wp_path_id": dirID
            ]
            if !uid.isEmpty { fields["uid"] = uid }
            if !sign.isEmpty {
                fields["sign"] = sign
                fields["time"] = time
            }
            let obj = try await form(URL(string: "https://115.com/web/lixian/?ct=lixian&ac=add_task_url")!, fields)
            return try parseOfflineAdd(obj)
        }
        var fields = ["wp_path_id": dirID]
        if !uid.isEmpty { fields["uid"] = uid }
        if !sign.isEmpty {
            fields["sign"] = sign
            fields["time"] = time
        }
        for (i, link) in links.enumerated() { fields["url[\(i)]"] = link }
        let obj = try await form(URL(string: "https://115.com/web/lixian/?ct=lixian&ac=add_task_urls")!, fields)
        return try parseOfflineAdd(obj)
    }

    static func listOffline(page: Int = 1) async throws -> (tasks: [OfflineTask], quota: Int64, pageCount: Int) {
        let urls = [
            "https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=\(page)",
            "https://lixian.115.com/lixian/?ct=lixian&ac=task_lists&page=\(page)"
        ]
        var last: Error = APIError.badResponse
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
                req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                req.httpBody = "page=\(page)".data(using: .utf8)
                let obj = try await playJSON(req)
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
                        size: Int64(string(item["size"]) ?? "0") ?? 0,
                        url: string(item["url"]) ?? "",
                        status: Int(string(item["status"]) ?? "0") ?? 0,
                        percent: Double(string(item["percentDone"] ?? item["percent"]) ?? "0") ?? 0,
                        fileID: string(item["file_id"] ?? item["delete_file_id"]) ?? "",
                        dirID: string(item["wp_path_id"]) ?? "",
                        addTime: Int64(string(item["add_time"]) ?? "0") ?? 0
                    )
                }
                let quota = Int64(string(obj["quota"]) ?? "0") ?? 0
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
                let obj = try await form(url, fields)
                if ok(obj) { return }
                last = APIError.message(string(obj["error"]) ?? string(obj["error_msg"]) ?? "删除离线任务失败")
            } catch {
                last = error
            }
        }
        throw last
    }

    static func clearOffline(flag: Int) async throws {
        let obj = try await form(URL(string: "https://115.com/web/lixian/?ct=lixian&ac=task_clear")!, [
            "flag": "\(flag)"
        ])
        guard ok(obj) else {
            throw APIError.message(string(obj["error"]) ?? "清空失败")
        }
    }

    private static func offlineSign() async throws -> (sign: String, time: String) {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let obj = try await json(URL(string: "https://115.com/?ct=offline&ac=space&_=\(ts)")!)
        guard let sign = string(obj["sign"]), !sign.isEmpty else {
            throw APIError.message("获取离线签名失败")
        }
        return (sign, string(obj["time"]) ?? "\(ts)")
    }

    private static func parseOfflineAdd(_ obj: [String: Any]) throws -> String {
        if ok(obj) { return "已加入离线任务" }
        let msg = string(obj["error_msg"]) ?? string(obj["error"]) ?? string(obj["msg"]) ?? ""
        let code = Int(string(obj["errcode"] ?? obj["errno"]) ?? "0") ?? 0
        if code == 10008 || msg.contains("已存在") || msg.contains("重复") {
            return "任务已存在"
        }
        throw APIError.message(msg.isEmpty ? "添加离线任务失败" : msg)
    }

    struct RecycleItem: Identifiable, Hashable {
        let id: String
        let name: String
        let isDir: Bool
        let size: Int64
    }

    static func recycleList() async throws -> [RecycleItem] {
        let obj = try await json(URL(string: "https://webapi.115.com/rb?aid=1&cid=0&offset=0&limit=1150&format=json")!)
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "回收站失败")
        }
        let rows = extractRows(obj)
        return rows.compactMap { item in
            let id = string(item["id"] ?? item["rid"] ?? item["fid"]) ?? ""
            guard !id.isEmpty else { return nil }
            let fc = string(item["fc"] ?? item["file_category"] ?? item["type"]) ?? ""
            let isDir = fc == "0" || string(item["is_dir"]) == "1"
            return RecycleItem(
                id: id,
                name: string(item["n"] ?? item["file_name"] ?? item["name"]) ?? id,
                isDir: isDir,
                size: Int64(string(item["s"] ?? item["file_size"] ?? item["size"]) ?? "0") ?? 0
            )
        }
    }

    static func recycleRevert(ids: [String]) async throws {
        var fields: [String: String] = [:]
        for (i, id) in ids.enumerated() { fields["rid[\(i)]"] = id }
        let obj = try await form(URL(string: "https://webapi.115.com/rb/revert")!, fields)
        guard ok(obj) else {
            throw APIError.message(string(obj["error"]) ?? "还原失败")
        }
    }

    static func recycleClean() async throws {
        let obj = try await form(URL(string: "https://webapi.115.com/rb/clean")!, ["password": ""])
        guard ok(obj) else {
            throw APIError.message(string(obj["error"]) ?? "清空回收站失败")
        }
    }

    static func parseShare(_ raw: String) -> (code: String, receive: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var code = ""
        var receive = ""
        if let url = URL(string: text), let host = url.host?.lowercased(),
           host.contains("115") || host.contains("anxia") {
            let parts = url.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "s"), i + 1 < parts.count {
                code = parts[i + 1].filter { $0.isLetter || $0.isNumber }
            }
            if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                receive = items.first(where: { ["password", "receive_code", "pwd"].contains($0.name) })?.value ?? ""
            }
        } else {
            let token = text.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).first.map(String.init) ?? ""
            code = token.filter { $0.isLetter || $0.isNumber }
        }
        return (code, receive)
    }

    /// 对照 OpenList 115_share：GET share/snap
    static func shareSnap(code: String, receive: String, cid: String = "0") async throws -> [Node] {
        guard !code.isEmpty else { throw APIError.message("缺少分享码") }
        var c = URLComponents(string: "https://webapi.115.com/share/snap")!
        c.queryItems = [
            URLQueryItem(name: "share_code", value: code),
            URLQueryItem(name: "receive_code", value: receive),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "limit", value: "1150"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "asc", value: "0"),
            URLQueryItem(name: "format", value: "json")
        ]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("https://115cdn.com/s/\(code)?password=\(receive)&", forHTTPHeaderField: "Referer")
        let obj = try await playJSON(req)
        if let state = obj["state"] as? Bool, state == false {
            let fallback = URL(string: "https://115cdn.com/webapi/share/snap?share_code=\(encode(code))&receive_code=\(encode(receive))&cid=\(encode(cid))&limit=1150&offset=0&format=json")!
            var r2 = URLRequest(url: fallback)
            r2.httpMethod = "GET"
            headers().forEach { r2.setValue($1, forHTTPHeaderField: $0) }
            let obj2 = try await playJSON(r2)
            if let state2 = obj2["state"] as? Bool, state2 == false {
                throw APIError.message(string(obj["error"]) ?? string(obj2["error"]) ?? "打开分享失败")
            }
            return extractRows(obj2["data"] as? [String: Any] ?? obj2).compactMap(parseNode)
        }
        let data = obj["data"] as? [String: Any] ?? obj
        return extractRows(data).compactMap(parseNode)
    }

    /// 对照 115 网页：把分享文件转存到自己的目录
    static func shareReceive(code: String, receive: String, fileIDs: [String], destCID: String) async throws {
        var fields = [
            "share_code": code,
            "receive_code": receive,
            "cid": destCID,
            "user_id": cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        ]
        let ids = fileIDs.filter { !$0.isEmpty }
        if ids.isEmpty {
            fields["file_id"] = "0"
        } else {
            for (i, id) in ids.enumerated() { fields["file_id[\(i)]"] = id }
            fields["file_id"] = ids.joined(separator: ",")
        }
        let obj = try await form(URL(string: "https://webapi.115.com/share/receive")!, fields)
        guard ok(obj) else {
            throw APIError.message(string(obj["error"]) ?? string(obj["error_msg"]) ?? "转存失败")
        }
    }

    private static func ok(_ obj: [String: Any]) -> Bool {
        if let b = obj["state"] as? Bool { return b }
        if let n = obj["state"] as? Int { return n == 1 }
        if let s = obj["state"] as? String { return s == "1" || s.lowercased() == "true" }
        return false
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

    static func initUpload(fileName: String, size: Int64, sha1: String, preSha1: String, dirID: String) async throws -> InitUpload {
        if let sample = try? await sampleInit(fileName: fileName, size: size, dirID: dirID) {
            return sample
        }
        return try await simpleInit(fileName: fileName, size: size, sha1: sha1, dirID: dirID)
    }

    private static func sampleInit(fileName: String, size: Int64, dirID: String) async throws -> InitUpload {
        let uid = cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        let obj = try await form(URL(string: "https://uplb.115.com/3.0/sampleinitupload.php")!, [
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
            rapid: false,
            fileID: nil,
            host: host,
            object: object,
            accessKeyId: string(obj["accessid"]) ?? string(obj["OSSAccessKeyId"]) ?? "",
            accessKeySecret: "",
            securityToken: string(obj["token"]) ?? "",
            callback: string(obj["callback"]) ?? "",
            callbackVar: string(obj["callback_var"]) ?? "",
            bucket: string(obj["bucket"]) ?? "",
            endpoint: host,
            formPolicy: string(obj["policy"]) ?? "",
            formSignature: string(obj["signature"]) ?? "",
            useForm: true
        )
    }

    private static func simpleInit(fileName: String, size: Int64, sha1: String, dirID: String) async throws -> InitUpload {
        let uid = cookieValue("UID")?.split(separator: "_").first.map(String.init) ?? ""
        let obj = try await form(URL(string: "https://uplb.115.com/3.0/initupload.php")!, [
            "appid": "0",
            "appversion": "27.0.5.7",
            "userid": uid,
            "filename": fileName,
            "filesize": "\(size)",
            "fileid": sha1,
            "target": "U_1_\(dirID)"
        ])
        let status = (obj["status"] as? Int) ?? Int(string(obj["status"]) ?? "-1") ?? -1
        if status == 1 || string(obj["statuscode"]) == "0" && obj["pickcode"] != nil {
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
            rapid: false,
            fileID: sha1,
            host: host,
            object: object,
            accessKeyId: string(obj["accessid"]) ?? "",
            accessKeySecret: string(obj["accesskey_secret"]) ?? "",
            securityToken: string(obj["token"]) ?? "",
            callback: string(obj["callback"]) ?? "",
            callbackVar: string(obj["callback_var"]) ?? "",
            bucket: string(obj["bucket"]) ?? "",
            endpoint: host,
            formPolicy: string(obj["policy"]) ?? "",
            formSignature: string(obj["signature"]) ?? "",
            useForm: !(string(obj["policy"]) ?? "").isEmpty
        )
    }

    /// 对照 OpenList：下载直链按 UA 绑定，播放/看图必须同一 UA。
    static let playUA = userAgent

    static func playHeaders() -> [String: String] {
        fileHeaders()
    }

    /// OpenList Link 头：同一 115Browser UA，不带 Origin。
    static func fileHeaders() -> [String: String] {
        var h = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Referer": "https://115.com/"
        ]
        if let cookie = Pan115Session.shared.cookieHeader {
            h["Cookie"] = cookie
        }
        return h
    }

    static func cdnHeaders() -> [String: String] {
        fileHeaders()
    }

    /// 对照 OpenList `DownloadWithUA`：原文件直链，视频/图片共用。
    static func downloadURL(pickCode: String) async throws -> URL {
        try await fileLink(pickCode: pickCode).url
    }

    static func fileLink(pickCode: String) async throws -> (url: URL, headers: [String: String]) {
        guard !pickCode.isEmpty else { throw APIError.message("缺少 pickcode") }
        if let u = try? await downloadWithUA(pickCode: pickCode, android: false) {
            return (u, fileHeaders())
        }
        if let u = try? await downloadWithUA(pickCode: pickCode, android: true) {
            return (u, fileHeaders())
        }
        let pc = uriEncode(pickCode)
        let candidates = [
            "https://proapi.115.com/android/2.0/ufile/download?pickcode=\(pc)",
            "https://webapi.115.com/files/download?pickcode=\(pc)",
            "https://webapi.115.com/files/download?pick_code=\(pc)"
        ]
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            var r = URLRequest(url: url)
            r.httpMethod = "GET"
            r.timeoutInterval = 20
            fileHeaders().forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            guard let obj = try? await playJSON(r), let u = firstHTTPURL(obj) else { continue }
            return (u, fileHeaders())
        }
        throw APIError.message("拿不到直链")
    }

    /// OpenList：POST proapi chrome/android downurl，body 为 m115 加密 pickcode。
    private static func downloadWithUA(pickCode: String, android: Bool) async throws -> URL {
        let key = Pan115M115.generateKey()
        let payloadObj: [String: String] = android
            ? ["pick_code": pickCode]
            : ["pickcode": pickCode]
        let payload = try JSONSerialization.data(withJSONObject: payloadObj)
        let encoded = Pan115M115.encode(payload, key: key)
        let t = Int(Date().timeIntervalSince1970)
        let endpoint = android
            ? "https://proapi.115.com/android/2.0/ufile/download?t=\(t)"
            : "https://proapi.115.com/app/chrome/downurl?t=\(t)"
        guard let url = URL(string: endpoint) else { throw APIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        fileHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.httpBody = "data=\(uriEncode(encoded))".data(using: .utf8)
        let obj = try await playJSON(req)
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "downurl 失败")
        }
        let blob: Data
        if let s = obj["data"] as? String, !s.isEmpty {
            blob = try Pan115M115.decode(s, key: key)
        } else if let u = firstHTTPURL(obj) {
            return u
        } else {
            throw APIError.badResponse
        }
        guard let decoded = try JSONSerialization.jsonObject(with: blob) as? Any,
              let u = extractDownloadURL(decoded) else {
            throw APIError.message("解密直链失败")
        }
        return u
    }

    private static func extractDownloadURL(_ any: Any) -> URL? {
        if let s = any as? String, s.hasPrefix("http") { return URL(string: s) }
        if let dict = any as? [String: Any] {
            if let u = firstHTTPURL(dict) { return u }
            if let nested = dict["url"] {
                if let u = extractDownloadURL(nested) { return u }
            }
            for value in dict.values {
                if let u = extractDownloadURL(value) { return u }
            }
        }
        if let arr = any as? [Any] {
            for value in arr {
                if let u = extractDownloadURL(value) { return u }
            }
        }
        return nil
    }

    static func playURL(pickCode: String, filename: String = "") async throws -> URL {
        try await playSource(pickCode: pickCode, filename: filename).url
    }

    /// 对照 OpenList：始终播原文件。mp4 也优先 FFmpeg，系统播放器兜底。
    static func playSource(pickCode: String, filename: String = "") async throws -> (url: URL, ffmpeg: Bool) {
        let url = try await downloadURL(pickCode: pickCode)
        return (url, true)
    }

    private static func transcodedStream(pickCode: String) async throws -> URL? {
        let pc = uriEncode(pickCode)
        let m3u8URL = URL(string: "https://115.com/api/video/m3u8/\(pc).m3u8")!
        var req = URLRequest(url: m3u8URL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        playHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              text.contains("#EXTM3U"),
              let best = parseMaster(text).first else { return nil }
        return URL(string: best)
    }

    private static func firstHTTPURL(_ obj: [String: Any]) -> URL? {
        func from(_ value: Any?) -> URL? {
            if let s = string(value), s.hasPrefix("http") { return URL(string: s) }
            if let dict = value as? [String: Any] {
                for key in ["url", "file_url", "download_url", "video_url"] {
                    if let s = string(dict[key]), s.hasPrefix("http") { return URL(string: s) }
                }
            }
            return nil
        }
        let data = obj["data"] as? [String: Any] ?? [:]
        for key in ["file_url", "download_url", "video_url", "url", "file_download_url"] {
            if let u = from(obj[key]) ?? from(data[key]) { return u }
        }
        return nil
    }

    static func isPlayable(_ name: String) -> Bool {
        [
            "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm",
            "ts", "m2ts", "mts", "m3u8", "iso", "mpg", "mpeg", "vob",
            "rm", "rmvb", "f4v", "asf", "3gp", "tp", "trp", "dat"
        ].contains(fileExt(name))
    }

    static func needsFFmpeg(_ name: String) -> Bool {
        isPlayable(name)
    }

    static func isImage(_ name: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif"].contains(fileExt(name))
    }

    static func fileExt(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    private static func parseMaster(_ text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        var scored: [(Int, String)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("#EXT-X-STREAM-INF"), i + 1 < lines.count {
                var u = lines[i + 1]
                if u.hasPrefix("https: //") { u = u.replacingOccurrences(of: "https: //", with: "https://") }
                if !u.hasPrefix("http"), let abs = URL(string: u, relativeTo: URL(string: "https://115.com/")) {
                    u = abs.absoluteString
                }
                if u.hasPrefix("http") {
                    let name = capture(line, #"NAME="([^"]+)""#) ?? ""
                    let height = Int(capture(line, #"RESOLUTION=\d+x(\d+)"#) ?? "") ?? 0
                    scored.append((qualityScore(name: name, height: height), u))
                }
            }
            i += 1
        }
        return scored.sorted { $0.0 > $1.0 }.map(\.1)
    }

    private static func qualityScore(name: String, height: Int) -> Int {
        switch name.uppercased() {
        case "BD": return 4
        case "UD": return 3
        case "HD": return 2
        case "SD": return 1
        case "LD": return 0
        default: break
        }
        if height >= 2160 { return 4 }
        if height >= 1080 { return 3 }
        if height >= 720 { return 2 }
        if height >= 480 { return 1 }
        return 0
    }

    private static func capture(_ line: String, _ pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              m.numberOfRanges > 1,
              let range = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func playJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        return obj
    }

    static func json(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpStatus(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.badResponse }
        return obj
    }

    static func form(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpStatus(http.statusCode) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        throw APIError.badResponse
    }

    static func headers() -> [String: String] {
        var h = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://115.com/",
            "Origin": origin
        ]
        if let cookie = Pan115Session.shared.cookieHeader {
            h["Cookie"] = cookie
        }
        return h
    }

    static func cookieValue(_ name: String) -> String? {
        guard let header = Pan115Session.shared.cookieHeader else { return nil }
        for part in header.split(separator: ";") {
            let bits = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if bits.count == 2, bits[0].caseInsensitiveCompare(name) == .orderedSame { return bits[1] }
        }
        return nil
    }

    private static func string(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let n = any as? Int { return String(n) }
        if let n = any as? Int64 { return String(n) }
        if let n = any as? Double { return String(Int64(n)) }
        return nil
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// 对齐 JS `encodeURIComponent`。
    private static func uriEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
