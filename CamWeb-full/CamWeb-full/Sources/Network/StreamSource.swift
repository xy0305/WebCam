import Foundation

struct ResolvedStream: Sendable {
    let username: String
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

enum StreamSource {
    static func resolve(username: String) async throws -> ResolvedStream {
        var last: Error = StreamSourceError.badResponse
        for _ in 0..<3 {
            do {
                let master = try await fetchMaster(username: username)
                if let text = try? await fetchMasterText(master), text.contains("#EXTM3U") {
                    if text.contains("#EXT-X-STREAM-INF") {
                        let parsed = parseMaster(text, base: master)
                        guard let video = parsed.variants.first?.url else {
                            return ResolvedStream(
                                username: username, hlsURL: master, masterURL: master,
                                videoPlaylist: master, audioPlaylist: nil, status: "public"
                            )
                        }
                        let hls: URL
                        if let audio = parsed.audioUri,
                           let mini = buildMiniMasterDataUri(
                                audioUri: audio, videoUrl: video,
                                bandwidth: parsed.variants.first?.bandwidth ?? 2_000_000,
                                resolution: parsed.variants.first?.resolution ?? ""
                           ) {
                            hls = mini
                        } else {
                            hls = master
                        }
                        return ResolvedStream(
                            username: username, hlsURL: hls, masterURL: master,
                            videoPlaylist: video, audioPlaylist: parsed.audioUri, status: "public"
                        )
                    }
                    return ResolvedStream(
                        username: username, hlsURL: master, masterURL: master,
                        videoPlaylist: master, audioPlaylist: nil, status: "public"
                    )
                }
                return ResolvedStream(
                    username: username, hlsURL: master, masterURL: master,
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

    /// 用 HLS 专用头拉 playlist 文本（不带 CSRF / Origin）
    private static func fetchMasterText(_ url: URL) async throws -> String {
        let (data, http) = try await APIClient.hlsData(for: url, retry: 1)
        guard (200..<300).contains(http.statusCode) else {
            throw StreamSourceError.httpStatus(http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 解析音视频分离的 master：提取 TYPE=AUDIO 的 URI，以及所有非 _audio_ 视频变体（按码率降序）
    private static func parseMaster(_ doc: String, base: URL) -> (audioUri: URL?, variants: [Variant]) {
        var audioUri: URL?
        var variants: [Variant] = []
        var pendingBandwidth = 0
        var pendingResolution = ""

        let lines = doc.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA:"), line.range(of: "TYPE=AUDIO", options: .caseInsensitive) != nil {
                if let r = line.range(of: "URI=\"", options: []) {
                    let after = line[r.upperBound...]
                    if let end = after.firstIndex(of: "\"") {
                        let uriStr = String(after[..<end])
                        audioUri = resolveAbsolute(uriStr, base: base)
                    }
                }
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                if let br = captureInt("BANDWIDTH=", in: line) { pendingBandwidth = br }
                if let rs = captureString("RESOLUTION=", in: line) { pendingResolution = rs }
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                if !line.contains("_audio_"), let abs = resolveAbsolute(line, base: base) {
                    variants.append(Variant(url: abs, bandwidth: pendingBandwidth, resolution: pendingResolution))
                }
                pendingBandwidth = 0
                pendingResolution = ""
            }
        }
        variants.sort { $0.bandwidth > $1.bandwidth }
        return (audioUri, variants)
    }

    private struct Variant {
        let url: URL
        let bandwidth: Int
        let resolution: String
    }

    /// 生成只含「一档视频 + 音频」的迷你 master → data: URI
    private static func buildMiniMasterDataUri(audioUri: URL, videoUrl: URL, bandwidth: Int, resolution: String) -> URL? {
        let resAttr = resolution.isEmpty ? "" : ",RESOLUTION=\(resolution)"
        let bw = bandwidth > 0 ? bandwidth : 2_000_000

        let m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio_aac_96",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="\(audioUri.absoluteString)"
        #EXT-X-STREAM-INF:BANDWIDTH=\(bw)\(resAttr),CODECS="avc1.4d401f,mp4a.40.2",AUDIO="audio_aac_96"
        \(videoUrl.absoluteString)
        """

        guard let data = m3u8.data(using: .utf8) else { return nil }
        let b64 = data.base64EncodedString()
        return URL(string: "data:application/vnd.apple.mpegurl;base64,\(b64)")
    }

    private static func captureInt(_ key: String, in line: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let after = line[r.upperBound...]
        let digits = after.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func captureString(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let after = line[r.upperBound...]
        if let comma = after.firstIndex(of: ",") {
            return String(after[..<comma])
        }
        return String(after)
    }

    private static func resolveAbsolute(_ str: String, base: URL) -> URL? {
        if str.hasPrefix("http://") || str.hasPrefix("https://") {
            return URL(string: str)
        }
        return URL(string: str, relativeTo: base)?.absoluteURL
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
