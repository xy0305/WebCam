import Foundation

struct HLSRequestContext: Sendable {
    let referer: String
    let origin: String?
    static let chaturbate = HLSRequestContext(referer: "https://chaturbate.com/", origin: nil)
    static func stripchat(username: String) -> HLSRequestContext {
        HLSRequestContext(referer: "https://zh.stripchat.com/\(username)/", origin: "https://zh.stripchat.com")
    }
    static func panda(roomId: String) -> HLSRequestContext {
        HLSRequestContext(referer: "https://www.pandalive.co.kr/play/\(roomId)", origin: "https://www.pandalive.co.kr")
    }
    var cookieHeader: String? {
        origin?.contains("pandalive") == true ? PandaSession.shared.cookieHeader : nil
    }
}

struct ResolvedStream: Sendable {
    let username: String
    let requestContext: HLSRequestContext
    /// 播放用：有声最高画质迷你 master（data: URI），AVPlayer 直接播
    let hlsURL: URL
    /// 官方原始 master
    let masterURL: URL
    /// 录制用：最高码率视频媒体 playlist（播放时已解析，不再回拉 master）
    let videoPlaylist: URL
    /// 录制用：音频媒体 playlist（音视频分离时才有）
    let audioPlaylist: URL?
    let status: String
}

/// 对照 AngelLive panda 插件：按分辨率高度、再按带宽从高到低锁最高档。
enum HLSMaster {
    struct Variant {
        let url: URL
        let bandwidth: Int
        let height: Int
        let resolution: String
    }

    struct Parsed {
        var audioUri: URL?
        var variants: [Variant] = []
        var best: Variant? { variants.first }
    }

    static func parse(_ doc: String, base: URL) -> Parsed {
        var audioUri: URL?
        var variants: [Variant] = []
        var pendingBandwidth = 0
        var pendingResolution = ""
        var pendingHeight = 0

        for raw in doc.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MEDIA:"), line.range(of: "TYPE=AUDIO", options: .caseInsensitive) != nil {
                if let uri = quotedURI(line), let url = resolve(uri, base: base) {
                    audioUri = url
                }
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = intAttribute("BANDWIDTH=", line) ?? 0
                pendingResolution = stringAttribute("RESOLUTION=", line) ?? ""
                pendingHeight = height(from: pendingResolution)
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                if !line.contains("_audio_"), let url = resolve(line, base: base) {
                    variants.append(Variant(
                        url: url,
                        bandwidth: pendingBandwidth,
                        height: pendingHeight,
                        resolution: pendingResolution
                    ))
                }
                pendingBandwidth = 0
                pendingResolution = ""
                pendingHeight = 0
            }
        }
        variants.sort {
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.bandwidth > $1.bandwidth
        }
        return Parsed(audioUri: audioUri, variants: variants)
    }

    static func fetchText(_ url: URL, context: HLSRequestContext) async throws -> String {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 12
        let panda = context.origin?.contains("pandalive") == true
        req.setValue(panda ? PandaAPI.userAgent : APIClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(context.referer, forHTTPHeaderField: "Referer")
        if let origin = context.origin, !origin.isEmpty {
            req.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let cookie = context.cookieHeader {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw StreamSourceError.badResponse
        }
        return text
    }

    /// 播放锁死单档：有独立音频就组迷你 master，否则直接播最高档媒体清单。
    static func lock(_ master: URL, context: HLSRequestContext) async -> (play: URL, video: URL, audio: URL?)? {
        guard let text = try? await fetchText(master, context: context), text.contains("#EXTM3U") else {
            return nil
        }
        guard text.contains("#EXT-X-STREAM-INF") else {
            return (master, master, nil)
        }
        let parsed = parse(text, base: master)
        guard let best = parsed.best else { return (master, master, parsed.audioUri) }
        if let audio = parsed.audioUri,
           let mini = miniMaster(audio: audio, video: best.url, bandwidth: best.bandwidth, resolution: best.resolution) {
            return (mini, best.url, audio)
        }
        if let play = oneVariantMaster(best) {
            return (play, best.url, parsed.audioUri)
        }
        return (best.url, best.url, parsed.audioUri)
    }

    static func oneVariantMaster(_ best: Variant) -> URL? {
        let resAttr = best.resolution.isEmpty ? "" : ",RESOLUTION=\(best.resolution)"
        let bw = best.bandwidth > 0 ? best.bandwidth : 5_000_000
        let m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=\(bw)\(resAttr)
        \(best.url.absoluteString)
        """
        guard let data = m3u8.data(using: .utf8) else { return nil }
        return URL(string: "data:application/vnd.apple.mpegurl;base64,\(data.base64EncodedString())")
    }

    static func miniMaster(audio: URL, video: URL, bandwidth: Int, resolution: String) -> URL? {
        let resAttr = resolution.isEmpty ? "" : ",RESOLUTION=\(resolution)"
        let bw = bandwidth > 0 ? bandwidth : 2_000_000
        let m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_aac_96",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="\(audio.absoluteString)"
        #EXT-X-STREAM-INF:BANDWIDTH=\(bw)\(resAttr),CODECS="avc1.4d401f,mp4a.40.2",AUDIO="audio_aac_96"
        \(video.absoluteString)
        """
        guard let data = m3u8.data(using: .utf8) else { return nil }
        return URL(string: "data:application/vnd.apple.mpegurl;base64,\(data.base64EncodedString())")
    }

    static func height(from resolution: String) -> Int {
        let parts = resolution.lowercased().split(separator: "x")
        if parts.count >= 2, let h = Int(parts[1].prefix(while: \.isNumber)) { return h }
        return Int(resolution.filter(\.isNumber)) ?? 0
    }

    private static func resolve(_ str: String, base: URL) -> URL? {
        if str.hasPrefix("http://") || str.hasPrefix("https://") { return URL(string: str) }
        return URL(string: str, relativeTo: base)?.absoluteURL
    }

    private static func quotedURI(_ line: String) -> String? {
        guard let r = line.range(of: "URI=\"") else { return nil }
        let after = line[r.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    private static func intAttribute(_ key: String, _ line: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        return Int(line[r.upperBound...].prefix(while: \.isNumber))
    }

    private static func stringAttribute(_ key: String, _ line: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let after = line[r.upperBound...]
        if let comma = after.firstIndex(of: ",") { return String(after[..<comma]) }
        return String(after)
    }
}

enum StreamSource {
    /// 统一入口：录制重连必须按房间平台重新解析，不能把 Stripchat 用户名送进 Chaturbate 接口。
    static func resolve(room: Room) async throws -> ResolvedStream {
        if room.platform == .stripchat { return try await StripchatStreamSource.resolve(room: room) }
        if room.platform == .panda { return try await PandaStreamSource.resolve(room: room) }
        return try await resolve(username: room.username)
    }

    static func resolve(username: String) async throws -> ResolvedStream {
        var last: Error = StreamSourceError.badResponse
        for _ in 0..<3 {
            do {
                let master = try await fetchMaster(username: username)
                if let locked = await HLSMaster.lock(master, context: .chaturbate) {
                    return ResolvedStream(
                        username: username, requestContext: .chaturbate, hlsURL: locked.play, masterURL: master,
                        videoPlaylist: locked.video, audioPlaylist: locked.audio, status: "public"
                    )
                }
                return ResolvedStream(
                    username: username, requestContext: .chaturbate, hlsURL: master, masterURL: master,
                    videoPlaylist: master, audioPlaylist: nil, status: "public"
                )
            } catch {
                last = error
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw last
    }

    /// 依次尝试 ajax 与 chatvideocontext，返回官方 master URL
    private static func fetchMaster(username: String) async throws -> URL {
        if let url = await fromAjax(username: username) {
            return url
        }
        return try await fromContext(username: username)
    }

    private static func fromAjax(username: String) async -> URL? {
        var req = URLRequest(url: URL(string: "https://chaturbate.com/get_edge_hls_url_ajax/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://chaturbate.com/\(username)/", forHTTPHeaderField: "Referer")
        req.httpBody = "room_slug=\(username)&bandwidth=high".data(using: .utf8)
        guard let (data, http) = try? await APIClient.data(for: req, retry: 1),
              (200..<300).contains(http.statusCode) else { return nil }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (obj["room_status"] as? String) ?? "unknown"
        guard status == "public" else { return nil }
        guard let raw = obj["url"] as? String, let url = URL(string: raw), !raw.isEmpty else {
            return nil
        }
        return url
    }

    private static func fromContext(username: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://chaturbate.com/api/chatvideocontext/\(username)/")!)
        req.setValue("https://chaturbate.com/\(username)/", forHTTPHeaderField: "Referer")
        let (data, http) = try await APIClient.data(for: req, retry: 1)
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.httpStatus(http.statusCode) }
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (obj["room_status"] as? String) ?? "unknown"
        guard status == "public" else { throw StreamSourceError.offline(status) }
        guard let raw = obj["hls_source"] as? String, let url = URL(string: raw), !raw.isEmpty else {
            throw StreamSourceError.blocked
        }
        return url
    }
}
