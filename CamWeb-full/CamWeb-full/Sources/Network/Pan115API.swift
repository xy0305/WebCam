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

    static func delete(id: String) async throws {
        let obj = try await form(URL(string: "https://webapi.115.com/rb/delete")!, [
            "fid[0]": id,
            "ignore_warn": "1"
        ])
        if let state = obj["state"] as? Bool, state == false {
            throw APIError.message(string(obj["error"]) ?? "删除失败")
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

    /// 必须与播放器 UA 一致，否则 115 按 UA 绑定的 m3u8 会 403。
    static let playUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"

    static func playHeaders() -> [String: String] {
        var h = [
            "User-Agent": playUA,
            "Accept": "*/*",
            "Origin": origin,
            "Referer": "https://115.com/"
        ]
        if let cookie = Pan115Session.shared.cookieHeader {
            h["Cookie"] = cookie
        }
        return h
    }

    /// 115 CDN 直链：再带 Cookie / Origin 经常 403。
    static func cdnHeaders() -> [String: String] {
        [
            "User-Agent": playUA,
            "Accept": "*/*",
            "Referer": "https://115.com/"
        ]
    }

    /// 原文件直链（可 seek）。转码没完成的 m3u8 只有 1 秒，进度条会废掉。
    static func downloadURL(pickCode: String) async throws -> URL {
        guard !pickCode.isEmpty else { throw APIError.message("缺少 pickcode") }
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
            headers().forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            guard let obj = try? await playJSON(r), let u = firstHTTPURL(obj) else { continue }
            return u
        }
        throw APIError.message("拿不到直链")
    }

    /// 对齐 build 36 / AVDB：先 115 转码 m3u8（完整时长、可 seek），再 video，最后才原文件。
    /// 原文件直链给 AVPlayer 时常只有 1 秒，ts/mkv 也播不了。
    static func playURL(pickCode: String, filename: String = "") async throws -> URL {
        try await playSource(pickCode: pickCode, filename: filename).url
    }

    static func playSource(pickCode: String, filename: String = "") async throws -> (url: URL, ffmpeg: Bool) {
        guard !pickCode.isEmpty else { throw APIError.message("缺少 pickcode") }
        let ffmpeg = needsFFmpeg(filename)
        // ts/avi/mkv 的转码 m3u8 经常只有 1 秒。直接原文件 + FFmpeg。
        if !ffmpeg, let hls = try? await transcodedStream(pickCode: pickCode) {
            return (hls, false)
        }
        let pc = uriEncode(pickCode)
        let candidates = [
            "https://115vod.com/webapi/files/video?pickcode=\(pc)&local=1",
            "https://webapi.115.com/files/video?pickcode=\(pc)&local=1"
        ]
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            var r = URLRequest(url: url)
            r.httpMethod = "GET"
            r.timeoutInterval = 15
            playHeaders().forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            guard let obj = try? await playJSON(r), let u = firstHTTPURL(obj) else { continue }
            return (u, true)
        }
        if let url = try? await downloadURL(pickCode: pickCode) {
            return (url, true)
        }
        throw APIError.message("拿不到播放地址")
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
        [
            "ts", "m2ts", "mts", "mkv", "avi", "wmv", "flv", "webm",
            "iso", "mpg", "mpeg", "vob", "rm", "rmvb", "f4v", "asf",
            "3gp", "tp", "trp", "dat"
        ].contains(fileExt(name))
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
