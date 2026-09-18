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

    static func list(cid: String, offset: Int = 0) async throws -> [Node] {
        var c = URLComponents(string: "https://webapi.115.com/files")!
        c.queryItems = [
            URLQueryItem(name: "aid", value: "1"),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "o", value: "user_ptime"),
            URLQueryItem(name: "asc", value: "0"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "115"),
            URLQueryItem(name: "show_dir", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        let obj = try await json(c.url!)
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "列出目录失败")
        }
        let rows = obj["data"] as? [[String: Any]] ?? []
        return rows.compactMap { parseNode($0) }
    }

    private static func parseNode(_ item: [String: Any]) -> Node? {
        let fid = string(item["fid"]) ?? ""
        let dirID = string(item["cid"]) ?? ""
        let fileCategory = string(item["fc"]) ?? string(item["file_category"])
        let isDir = fid.isEmpty || fileCategory == "0"
        let id = isDir ? (dirID.isEmpty ? fid : dirID) : fid
        guard !id.isEmpty else { return nil }
        return Node(
            id: id,
            name: string(item["n"]) ?? string(item["fn"]) ?? string(item["file_name"]) ?? id,
            isDir: isDir,
            size: Int64(string(item["s"]) ?? string(item["file_size"]) ?? "0") ?? 0,
            pickCode: string(item["pc"]) ?? string(item["pick_code"]) ?? ""
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
        let rows = obj["data"] as? [[String: Any]] ?? []
        return rows.compactMap { parseNode($0) }
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
        if let n = any as? Int { return String(n) }
        if let n = any as? Int64 { return String(n) }
        return nil
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
