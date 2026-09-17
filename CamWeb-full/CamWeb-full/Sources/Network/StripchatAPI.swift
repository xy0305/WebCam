import Foundation

enum StripchatAPI {
    static let host = "https://zh.stripchat.com"

    static var headers: [String: String] {
        var h = [
            "User-Agent": APIClient.userAgent,
            "Accept": "application/json",
            "Referer": "https://zh.stripchat.com/",
            "Origin": "https://zh.stripchat.com"
        ]
        if let cookie = StripchatSession.shared.cookieHeader {
            h["Cookie"] = cookie
        }
        return h
    }

    struct Model: Decodable {
        let id: Int
        let username: String
        let status: String?
        let gender: String?
        let country: String?
        let viewersCount: Int?
        let avatarUrl: String?
        let previewUrlThumbSmall: String?
        let snapshotTimestamp: FlexibleString?
        let popularSnapshotTimestamp: FlexibleString?
        let presets: [String]?
        let isHd: Bool?
        let isNew: Bool?

        func room() -> Room {
            let cover: String?
            if let stamp = snapshotTimestamp?.value {
                cover = "https://img.doppiocdn.com/thumbs/\(stamp)/\(id)"
            } else if let stamp = popularSnapshotTimestamp?.value {
                cover = "https://img.doppiocdn.com/thumbs/\(stamp)/\(id)"
            } else {
                cover = StripchatAPI.absolute(previewUrlThumbSmall ?? avatarUrl)
            }
            var tags: [String] = []
            if let gender { tags.append(gender) }
            if let country { tags.append(country) }
            if isHd == true { tags.append("hd") }
            return Room(
                platform: .stripchat,
                platformRoomID: String(id),
                username: username,
                displayName: username,
                roomSubject: status == "public" ? "Live" : (status ?? "Offline"),
                numUsers: viewersCount,
                imageURL: cover,
                tags: tags.isEmpty ? nil : tags,
                presets: presets
            )
        }
    }

    struct FlexibleString: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { value = String(n); return }
            if let n = try? c.decode(Int64.self) { value = String(n); return }
            if let s = try? c.decode(String.self) { value = s; return }
            throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "expected string or number"))
        }
    }

    struct Response: Decodable {
        struct Block: Decodable { let models: [Model]? }
        let models: [Model]?
        let blocks: [Block]?
        let favorites: [Model]?
        let items: [Model]?
        var all: [Model] {
            var seen = Set<Int>()
            var out: [Model] = []
            let blockModels = blocks?.compactMap(\.models).flatMap { $0 } ?? []
            let allModels = models ?? []
            let allFavorites = favorites ?? []
            let allItems = items ?? []
            for m in allModels + blockModels + allFavorites + allItems {
                if seen.insert(m.id).inserted { out.append(m) }
            }
            return out
        }
    }

    static func fetch(offset: Int, primary: String = "girls", tag: String? = nil, sort: String = "viewersCount") async throws -> [Room] {
        var c = URLComponents(string: host + "/api/front/v2/models")!
        c.queryItems = [
            URLQueryItem(name: "limit", value: "24"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "sortBy", value: sort),
            URLQueryItem(name: "primaryTag", value: primary)
        ]
        if let tag, !tag.isEmpty {
            c.queryItems?.append(URLQueryItem(name: "tag", value: tag))
        }
        return try await requestRooms(c.url!)
    }

    static func search(_ query: String, offset: Int = 0) async throws -> [Room] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        if let exact = try? await lookupUsername(q) {
            return [exact]
        }
        let rooms = try await fetch(offset: offset, primary: "girls", sort: "viewersCount")
        let kw = q.lowercased()
        return rooms.filter { $0.username.contains(kw) || ($0.title.lowercased().contains(kw)) }
    }

    static func lookupUsername(_ raw: String) async throws -> Room? {
        let name = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard name.count >= 2 else { return nil }
        var last: Error?
        for primary in ["girls", "couples", "men"] {
            do {
                let rooms = try await fetch(offset: 0, primary: primary, sort: "viewersCount")
                if let hit = rooms.first(where: { $0.username == name }) { return hit }
            } catch {
                last = error
            }
        }
        if let last { throw last }
        return nil
    }

    static func fetchRecommended(excluding username: String) async -> [Room] {
        (try? await fetch(offset: 0, primary: "girls", sort: "recommended"))?
            .filter { $0.username != username.lowercased() } ?? []
    }

    static func fetchFavorites(offset: Int = 0) async throws -> [Room] {
        guard StripchatSession.shared.cookieHeader != nil else { throw StreamSourceError.needLogin }
        let urls = [
            host + "/api/front/models/favorites?sortBy=lastAdded&limit=24&offset=\(offset)",
            host + "/api/front/models/favorites?sortBy=username&limit=24&offset=\(offset)",
            host + "/api/front/models/favorites/online?sortBy=lastAdded&limit=24&offset=\(offset)"
        ]
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            if let rooms = try? await requestRooms(url), !rooms.isEmpty { return rooms }
        }
        return []
    }

    private static func requestRooms(_ url: URL) async throws -> [Room] {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw StreamSourceError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw StreamSourceError.needLogin }
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(Response.self, from: data).all.map { $0.room() }
    }

    static func absolute(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.hasPrefix("http") ? value : "https://static-cdn.strpst.com\(value)"
    }
}

enum StripchatStreamSource {
    private static let cdnHosts = ["saawsedge.com", "growcdnssedge.com", "doppiocdn.com", "doppiocdn.org", "doppiocdn.live", "doppiocdn.net"]

    static func resolve(room: Room) async throws -> ResolvedStream {
        let id = try await modelID(for: room)
        let context = HLSRequestContext.stripchat(username: room.username)
        async let keysTask = StripchatMouflon.keys()
        let (master, text) = try await fetchAutoPlaylist(id: id, context: context)
        guard text.contains("#EXTM3U") else { throw StreamSourceError.badResponse }
        let keys = mouflonKeys(in: text)
        let pdkeys = await keysTask
        let matched = keys.first { pdkeys[$0] != nil } ?? keys.first
        let pdkey = matched.flatMap { pdkeys[$0] }
        let mediaURL: URL
        if text.contains("#EXT-X-STREAM-INF") {
            let variants = parseVariants(text, base: master)
            guard let best = variants.first else { throw StreamSourceError.blocked }
            mediaURL = decorate(best.url.absoluteString, base: best.url, pkey: matched, lowLatency: true) ?? best.url
        } else {
            mediaURL = decorate(master.absoluteString, base: master, pkey: matched, lowLatency: true) ?? master
        }
        let playURL = try await StripchatPlaylistProxy.shared.playbackURL(
            id: id, remote: mediaURL, context: context, keys: keys, pdkey: pdkey
        )
        return ResolvedStream(
            username: room.username,
            requestContext: context,
            hlsURL: playURL,
            masterURL: master,
            videoPlaylist: mediaURL,
            audioPlaylist: nil,
            status: room.roomSubject ?? "public"
        )
    }

    private static func modelID(for room: Room) async throws -> String {
        if let id = room.platformRoomID, !id.isEmpty { return id }
        return try await fetchBroadcastID(username: room.username)
    }

    private static func fetchBroadcastID(username: String) async throws -> String {
        let urls = [
            "\(StripchatAPI.host)/api/front/v1/broadcasts/\(username)",
            "https://stripchat.com/api/front/v1/broadcasts/\(username)"
        ]
        var last: Error = StreamSourceError.badResponse
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            do {
                var req = URLRequest(url: url)
                StripchatAPI.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                req.setValue("https://zh.stripchat.com/\(username)", forHTTPHeaderField: "Referer")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let item = obj["item"] as? [String: Any] else {
                    throw StreamSourceError.badResponse
                }
                if let name = item["streamName"] as? String, !name.isEmpty { return name }
                if let id = item["id"] as? Int { return String(id) }
                if let id = item["id"] as? String, !id.isEmpty { return id }
            } catch {
                last = error
            }
        }
        throw last
    }

    private static func fetchAutoPlaylist(id: String, context: HLSRequestContext) async throws -> (URL, String) {
        var urls: [URL] = []
        for host in cdnHosts {
            if let url = URL(string: "https://edge-hls.\(host)/hls/\(id)/master/\(id)_auto.m3u8") {
                urls.append(url)
            }
        }
        return try await racePlaylist(urls, context: context) { text in
            text.contains("#EXTM3U")
        }
    }

    static func playlistText(_ url: URL, context: HLSRequestContext) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(APIClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(context.referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw StreamSourceError.badResponse
        }
        return text
    }

    static func mouflonKeys(in text: String) -> [String] {
        var keys: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MOUFLON:PSCH:") else { continue }
            let parts = line.split(separator: ":")
            guard let key = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { continue }
            if keys.contains(key) == false { keys.append(key) }
        }
        return keys
    }

    static func withPkey(_ url: URL, key: String) -> URL? {
        decorate(url.absoluteString, base: url, pkey: key)
    }

    static func mediaText(_ url: URL, keys: [String], context: HLSRequestContext) async throws -> String {
        let media = try await pickWorkingMedia(url, keys: keys, prefer: keys.last, context: context)
        return try await playlistText(media, context: context)
    }

    static func pickWorkingMedia(_ url: URL, keys: [String], prefer: String?, context: HLSRequestContext) async throws -> URL {
        func usable(_ text: String) -> Bool {
            if text.contains("#EXT-X-MOUFLON-ADVERT") { return false }
            if text.contains("#EXT-X-MOUFLON:URI:") { return true }
            return text.contains("#EXTINF:") && text.contains("media.mp4") == false
        }
        if let prefer, let candidate = withPkey(url, key: prefer),
           let text = try? await playlistText(candidate, context: context), usable(text) {
            return candidate
        }
        var candidates: [URL] = []
        func add(_ item: URL?) {
            guard let item, candidates.contains(item) == false else { return }
            candidates.append(item)
        }
        if let last = keys.last { add(withPkey(url, key: last)) }
        add(url)
        let (picked, _) = try await racePlaylist(candidates, context: context, accept: usable)
        return picked
    }

    private static func racePlaylist(_ urls: [URL], context: HLSRequestContext, accept: @escaping @Sendable (String) -> Bool) async throws -> (URL, String) {
        try await withThrowingTaskGroup(of: (URL, String).self) { group in
            for url in urls {
                group.addTask {
                    let text = try await playlistText(url, context: context)
                    guard accept(text) else { throw StreamSourceError.badResponse }
                    return (url, text)
                }
            }
            var last: Error = StreamSourceError.badResponse
            while true {
                do {
                    guard let value = try await group.next() else { break }
                    group.cancelAll()
                    return value
                } catch {
                    last = error
                }
            }
            throw last
        }
    }

    private static func parseVariants(_ text: String, base: URL) -> [(bandwidth: Int, url: URL)] {
        var out: [(Int, URL)] = []
        var bandwidth = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                bandwidth = intAttribute("BANDWIDTH=", line) ?? 0
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = decorate(line, base: base, pkey: nil) {
                out.append((bandwidth, url))
                bandwidth = 0
            }
        }
        return out.sorted { $0.0 > $1.0 }
    }

    static func decorate(_ value: String, base: URL, pkey: String?, lowLatency: Bool = false) -> URL? {
        guard let absolute = URL(string: value, relativeTo: base)?.absoluteURL ?? URL(string: value),
              var comps = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else {
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
        var items = comps.queryItems ?? []
        func set(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        if lowLatency { set("playlistType", "lowLatency") }
        if let pkey, !pkey.isEmpty {
            set("psch", "v2")
            set("pkey", pkey)
        }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    private static func intAttribute(_ key: String, _ line: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        return Int(line[r.upperBound...].prefix(while: { $0.isNumber }))
    }
}
