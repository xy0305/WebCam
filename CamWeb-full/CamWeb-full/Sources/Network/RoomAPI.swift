import Foundation

enum RoomAPI {
    static func fetchRooms(offset: Int = 0, gender: String? = nil, keywords: String? = nil) async throws -> [Room] {
        var comp = URLComponents(string: "https://chaturbate.com/api/ts/roomlist/room-list/")!
        var items = [
            URLQueryItem(name: "limit", value: "80"),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let gender, !gender.isEmpty {
            items.append(URLQueryItem(name: "genders", value: gender))
        }
        if let keywords, !keywords.isEmpty {
            items.append(URLQueryItem(name: "keywords", value: keywords))
        }
        comp.queryItems = items
        var req = URLRequest(url: comp.url!)
        let (data, http) = try await APIClient.data(for: req)
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
        let decoded = try JSONDecoder().decode(RoomListResponse.self, from: data)
        return decoded.rooms ?? []
    }

    static func fetchFollowed() async throws -> [Room] {
        var comp = URLComponents(string: "https://chaturbate.com/api/ts/roomlist/room-list/")!
        comp.queryItems = [
            URLQueryItem(name: "limit", value: "80"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "follow", value: "1"),
        ]
        var req = URLRequest(url: comp.url!)
        let (data, http) = try await APIClient.data(for: req)
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamSourceError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
        let decoded = try JSONDecoder().decode(RoomListResponse.self, from: data)
        return decoded.rooms ?? []
    }

    /// 精确查用户名（chatvideocontext）。用户存在就返回，离线也返回卡片。
    static func lookupUsername(_ raw: String) async -> Room? {
        let name = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard name.count >= 2 else { return nil }
        var req = URLRequest(url: URL(string: "https://chaturbate.com/api/chatvideocontext/\(name)/")!)
        req.setValue("https://chaturbate.com/\(name)/", forHTTPHeaderField: "Referer")
        guard let (data, http) = try? await APIClient.data(for: req, retry: 1),
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let status = ((obj["room_status"] as? String) ?? "").lowercased()
        if status == "not-found" || status == "missing" || status == "error" { return nil }
        let title = (obj["room_title"] as? String)
            ?? (obj["broadcaster_username"] as? String)
            ?? name
        let viewers = (obj["num_viewers"] as? Int)
            ?? (obj["num_users"] as? Int)
            ?? (obj["viewers"] as? Int)
        let load: CardLoadState
        switch status {
        case "public", "private", "hidden", "away", "password":
            load = .live
        case "offline", "":
            load = status == "offline" ? .offline : .live
        default:
            load = .offline
        }
        return Room(
            username: name,
            displayName: (obj["broadcaster_username"] as? String) ?? name,
            roomSubject: title,
            numUsers: viewers,
            loadState: load
        )
    }

    /// 用户名直查 + 关键词房间列表，用户名匹配的排最前。
    static func search(_ query: String) async throws -> [Room] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        async let exact = lookupUsername(q)
        async let listed = fetchRooms(keywords: q)
        let user = await exact
        let rooms = (try? await listed) ?? []
        var out: [Room] = []
        var seen = Set<String>()
        if let user {
            out.append(user)
            seen.insert(user.username)
        }
        for r in rooms where seen.insert(r.username).inserted {
            out.append(r)
        }
        return out
    }
}
