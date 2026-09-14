import Foundation

enum StripchatAPI {
    static let host = "https://zh.stripchat.com"
    static let headers = [
        "User-Agent": APIClient.userAgent,
        "Accept": "application/json",
        "Referer": "https://zh.stripchat.com/",
        "Origin": "https://zh.stripchat.com"
    ]

    struct Model: Decodable {
        let id: Int
        let username: String
        let status: String?
        let viewersCount: Int?
        let avatarUrl: String?
        let previewUrlThumbSmall: String?
        let snapshotTimestamp: String?
        // Stripchat 同一响应中该字段为 JSON number，不是字符串；类型不符会让整页解码失败。
        let popularSnapshotTimestamp: Int?
        let presets: [String]?

        func room() -> Room {
            let cover: String?
            if let stamp = snapshotTimestamp { cover = "https://img.doppiocdn.com/thumbs/\(stamp)/\(id)" }
            else if let stamp = popularSnapshotTimestamp { cover = "https://img.doppiocdn.com/thumbs/\(stamp)/\(id)" }
            else { cover = StripchatAPI.absolute( previewUrlThumbSmall ?? avatarUrl ) }
            return Room(platform: .stripchat, platformRoomID: String(id), username: username,
                        displayName: username, roomSubject: status == "public" ? "Live" : "Offline",
                        numUsers: viewersCount, imageURL: cover, tags: nil, presets: presets)
        }
    }

    struct Response: Decodable {
        struct Block: Decodable { let models: [Model]? }
        let models: [Model]?
        let blocks: [Block]?
    }

    static func fetch(offset: Int, primary: String = "girls", tag: String? = nil, sort: String = "recommended") async throws -> [Room] {
        var c = URLComponents(string: host + "/api/front/v2/models")!
        c.queryItems = [URLQueryItem(name: "limit", value: "24"), URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "sortBy", value: sort), URLQueryItem(name: "primaryTag", value: primary)]
        if let tag, !tag.isEmpty { c.queryItems?.append(URLQueryItem(name: "tag", value: tag)) }
        var req = URLRequest(url: c.url!)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.models ?? decoded.blocks?.flatMap { $0.models ?? [] } ?? []).map { $0.room() }
    }

    static func absolute(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.hasPrefix("http") ? value : "https://static-cdn.strpst.com\(value)"
    }
}

enum StripchatStreamSource {
    static func resolve(room: Room) async throws -> ResolvedStream {
        guard let id = room.platformRoomID, !id.isEmpty else { throw StreamSourceError.badResponse }
        let bases = ["https://edge-hls.saawsedge.com/hls/\(id)/master/", "https://edge-hls.growcdnssedge.com/hls/\(id)/master/", "https://edge-hls.doppiocdn.com/hls/\(id)/master/"]
        var last: Error = StreamSourceError.blocked
        for base in bases {
            guard let master = URL(string: base + "\(id)_auto.m3u8") else { continue }
            do {
                var req = URLRequest(url: master)
                req.timeoutInterval = 15
                req.setValue(APIClient.userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                req.setValue("https://zh.stripchat.com/", forHTTPHeaderField: "Referer")
                req.setValue("https://zh.stripchat.com", forHTTPHeaderField: "Origin")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), String(data: data, encoding: .utf8)?.contains("#EXTM3U") == true else { continue }
                return ResolvedStream(username: room.username, hlsURL: master, masterURL: master, videoPlaylist: master, audioPlaylist: nil, status: "public")
            } catch { last = error }
        }
        throw last
    }
}
