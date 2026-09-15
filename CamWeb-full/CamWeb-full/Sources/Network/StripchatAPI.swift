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
        let context = HLSRequestContext.stripchat(username: room.username)
        let bases = ["https://edge-hls.saawsedge.com/hls/\(id)/master/", "https://edge-hls.growcdnssedge.com/hls/\(id)/master/", "https://edge-hls.doppiocdn.com/hls/\(id)/master/"]
        var last: Error = StreamSourceError.blocked
        for base in bases {
            guard let master = URL(string: base + "\(id)_auto.m3u8") else { continue }
            do {
                let text = try await playlistText(master, context: context)
                guard text.contains("#EXTM3U"), !text.contains("#EXT-X-MOUFLON") else { continue }
                let parsed = parseMaster(text, base: master)
                // _auto.m3u8 是 master 时必须取真实 media playlist；直接媒体清单则直接使用。
                let video = parsed.variants.first ?? master
                let hls = parsed.audio.flatMap { miniMaster(video: video, audio: $0) } ?? master
                return ResolvedStream(username: room.username, requestContext: context, hlsURL: hls,
                                      masterURL: master, videoPlaylist: video,
                                      audioPlaylist: parsed.audio, status: "public")
            } catch { last = error }
        }
        throw last
    }

    private static func playlistText(_ url: URL, context: HLSRequestContext) async throws -> String {
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.setValue(APIClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(context.referer, forHTTPHeaderField: "Referer")
        if let origin = context.origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let text = String(data: data, encoding: .utf8) else { throw StreamSourceError.badResponse }
        return text
    }

    private static func parseMaster(_ text: String, base: URL) -> (audio: URL?, variants: [URL]) {
        var audio: URL?; var variants: [(Int, URL)] = []; var bandwidth = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=AUDIO"), let uri = quotedURI(line) { audio = absolute(uri, base: base) }
            else if line.hasPrefix("#EXT-X-STREAM-INF:") { bandwidth = intAttribute("BANDWIDTH=", line) ?? 0 }
            else if !line.isEmpty, !line.hasPrefix("#"), let url = absolute(line, base: base) { variants.append((bandwidth, url)); bandwidth = 0 }
        }
        return (audio, variants.sorted { $0.0 > $1.0 }.map(\.1))
    }
    private static func quotedURI(_ line: String) -> String? {
        guard let r = line.range(of: "URI=\"") else { return nil }; let rest = line[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
    private static func intAttribute(_ key: String, _ line: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }; return Int(line[r.upperBound...].prefix(while: { $0.isNumber }))
    }
    private static func absolute(_ value: String, base: URL) -> URL? { URL(string: value, relativeTo: base)?.absoluteURL }
    private static func miniMaster(video: URL, audio: URL) -> URL? {
        let text = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audio.absoluteString)\"\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO=\"audio\"\n\(video.absoluteString)\n"
        return URL(string: "data:application/vnd.apple.mpegurl;base64," + Data(text.utf8).base64EncodedString())
    }
}
