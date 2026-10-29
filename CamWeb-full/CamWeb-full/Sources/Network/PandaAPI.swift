import Foundation

enum PandaAPI {
    static let apiHost = "https://api.pandalive.co.kr"
    static let webHost = "https://www.pandalive.co.kr"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static var headers: [String: String] {
        var h = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7",
            "Origin": webHost,
            "Referer": webHost + "/"
        ]
        if let cookie = PandaSession.shared.cookieHeader {
            h["Cookie"] = cookie
        }
        return h
    }

    static func fetch(offset: Int, sort: String = "user") async throws -> [Room] {
        let onlyNew = sort == "newbj" ? "Y" : "N"
        let order = sort == "newbj" ? "user" : sort
        let obj = try await post("/v1/live/index", [
            "onlyNewBj": onlyNew,
            "orderBy": order,
            "limit": "24",
            "offset": "\(offset)"
        ], referer: webHost + "/live")
        guard bool(obj["result"], true), let list = obj["list"] as? [[String: Any]] else {
            throw StreamSourceError.badResponse
        }
        return list.compactMap(room(fromLive:))
    }

    static func search(_ query: String, offset: Int = 0) async throws -> [Room] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let obj = try await post("/v1/live/bj_list", [
            "searchVal": q,
            "limit": "20",
            "offset": "\(offset)"
        ], referer: webHost + "/live")
        guard bool(obj["result"], true), let list = obj["list"] as? [[String: Any]] else {
            throw StreamSourceError.badResponse
        }
        return list.compactMap(room(fromSearch:))
    }

    static func fetchRecommended(excluding username: String) async -> [Room] {
        (try? await fetch(offset: 0, sort: "hot"))?
            .filter { $0.username.lowercased() != username.lowercased() } ?? []
    }

    static func loginName() async -> String? {
        guard PandaSession.shared.cookieHeader != nil else { return nil }
        guard let obj = try? await get("/v1/member/login_info") else { return nil }
        let info = dict(obj["loginInfo"])
        let user = dict(info["userInfo"])
        let logged = bool(user["isLogin"], false) || int(user["isLogin"]) == 1
        guard logged else { return nil }
        return string(user["nick"]) ?? string(user["nickname"]) ?? string(user["userNick"]) ?? string(user["id"])
    }

    private static func room(fromLive item: [String: Any]) -> Room? {
        let media = dict(item["media"])
        let userId = string(media["userId"]) ?? string(item["userId"])
        let userIdx = string(media["userIdx"]) ?? string(item["userIdx"])
        let nick = string(media["userNick"]) ?? string(item["userNick"]) ?? userId
        guard let userId, !userId.isEmpty else { return nil }
        let cover = string(media["thumbUrl"]) ?? string(media["thumbUrlOrigin"])
            ?? string(media["ivsThumbnail"]) ?? string(item["thumbUrl"])
        let viewers = int(media["user"]) ?? int(media["playCnt"]) ?? int(item["userCnt"])
        let live = bool(media["isLive"], true)
        return Room(
            platform: .panda,
            platformRoomID: userIdx,
            username: userId,
            displayName: nick,
            roomSubject: string(media["title"]) ?? string(item["channelTitle"]),
            numUsers: viewers,
            imageURL: cover,
            tags: live ? ["live"] : ["offline"]
        )
    }

    private static func room(fromSearch item: [String: Any]) -> Room? {
        let userId = string(item["userId"])
        guard let userId, !userId.isEmpty else { return nil }
        return Room(
            platform: .panda,
            platformRoomID: string(item["userIdx"]),
            username: userId,
            displayName: string(item["userNick"]) ?? userId,
            roomSubject: string(item["userNick"]),
            numUsers: int(item["scoreMonth"]) ?? int(item["scoreWeek"]),
            imageURL: string(item["thumbUrl"])
        )
    }

    static func post(_ path: String, _ params: [String: String], referer: String) async throws -> [String: Any] {
        guard let url = URL(string: apiHost + path) else { throw StreamSourceError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.httpBody = params.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw StreamSourceError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamSourceError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.httpStatus(http.statusCode) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func get(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: apiHost + path) else { throw StreamSourceError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StreamSourceError.badResponse
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? Int { return String(n) }
        if let n = value as? Int64 { return String(n) }
        if let n = value as? Double { return String(Int(n)) }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Int64 { return Int(n) }
        if let n = value as? Double { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func bool(_ value: Any?, _ fallback: Bool) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? Int { return n != 0 }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            return ["1", "true", "Y", "yes"].contains(s)
        }
        return fallback
    }

    static func dict(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }
}

enum PandaStreamSource {
    static func resolve(room: Room) async throws -> ResolvedStream {
        let userId = room.username
        let idx = try await userIdx(for: room)
        let play = try await PandaAPI.post("/v1/live/play", [
            "action": "watch",
            "userId": idx
        ], referer: "\(PandaAPI.webHost)/play/\(userId)")
        if PandaAPI.bool(play["result"], true) == false {
            let code = PandaAPI.string(PandaAPI.dict(play["errorData"])["code"]) ?? ""
            if code == "castEnd" { throw StreamSourceError.offline("offline") }
            throw StreamSourceError.needLogin
        }
        let info = PandaAPI.dict(play["media"])
        if PandaAPI.bool(info["isLive"], true) == false {
            throw StreamSourceError.offline("offline")
        }
        if PandaAPI.bool(info["isPw"], false) {
            throw StreamSourceError.blocked
        }
        let master = try firstPlaylist(play)
        let context = HLSRequestContext.panda(roomId: userId)
        if let locked = await HLSMaster.lock(master, context: context) {
            return ResolvedStream(
                username: userId,
                requestContext: context,
                hlsURL: locked.play,
                masterURL: master,
                videoPlaylist: locked.video,
                audioPlaylist: locked.audio,
                status: "public"
            )
        }
        return ResolvedStream(
            username: userId,
            requestContext: context,
            hlsURL: master,
            masterURL: master,
            videoPlaylist: master,
            audioPlaylist: nil,
            status: "public"
        )
    }

    private static func userIdx(for room: Room) async throws -> String {
        if let id = room.platformRoomID, !id.isEmpty { return id }
        if room.username.allSatisfy(\.isNumber) { return room.username }
        let member = try await PandaAPI.post("/v1/member/bj", [
            "userId": room.username
        ], referer: "\(PandaAPI.webHost)/play/\(room.username)")
        let info = PandaAPI.dict(member["bjInfo"])
        if let idx = PandaAPI.string(info["idx"]) ?? PandaAPI.string(info["id"]), !idx.isEmpty {
            return idx
        }
        throw StreamSourceError.badResponse
    }

    private static func firstPlaylist(_ play: [String: Any]) throws -> URL {
        let list = PandaAPI.dict(play["PlayList"])
        for key in ["hls3", "hls2", "hls"] {
            guard let items = list[key] as? [[String: Any]] else { continue }
            for item in items {
                if let raw = PandaAPI.string(item["url"]), let url = URL(string: raw) {
                    return url
                }
            }
        }
        throw StreamSourceError.blocked
    }
}
