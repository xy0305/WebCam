import Foundation

/// HLS helpers for the live-caption side reader.
///
/// The caption reader must never open the player's master playlist with FFmpeg's HLS demuxer:
/// FFmpeg probes every variant (downloads video segments of all renditions) before it emits audio,
/// which costs 20–30 s and steals bandwidth from the player. Instead we resolve the master in Swift and
/// hand FFmpeg a single audio-only (or lowest-bitrate) media playlist.
enum LiveCaptionHLS {
    enum Playlist: Equatable, Sendable {
        /// Master playlist; `audioURL` is the best media playlist for an audio-only read.
        case master(audioURL: URL)
        /// Already a media playlist (has segments) — use as-is.
        case media
        /// Body is not an M3U8 (e.g. Chaturbate `w3: session_duplicated`, HTML error page).
        case invalid(String)
    }

    /// Platforms whose play URL token is single-use (a second GET of the same master returns
    /// `session_duplicated` / 403). The caption reader must mint its own play URL for these and never
    /// touch the player's URL (racing the player for the token would break playback).
    static let singleUsePlaylistLiveTypes: Set<String> = ["chaturbate"]

    static func requiresFreshPlaylist(liveType: String) -> Bool {
        singleUsePlaylistLiveTypes.contains(liveType.lowercased())
    }

    static func looksLikeHLS(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8" || s.contains(".m3u8")
    }

    static func classify(_ text: String, baseURL: URL) -> Playlist {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("#EXTM3U") else {
            return .invalid(String(body.prefix(120)))
        }
        if body.contains("#EXT-X-STREAM-INF") || (body.contains("#EXT-X-MEDIA:") && !body.contains("#EXTINF")) {
            if let url = preferredAudioURL(master: body, baseURL: baseURL) {
                return .master(audioURL: url)
            }
            return .invalid("master playlist without usable variant")
        }
        return .media
    }

    /// Prefer a separate `TYPE=AUDIO` rendition (Chaturbate / MMCDN LL-HLS ships audio as its own
    /// fMP4 chunklist), choosing the group used by the lowest-bandwidth variant and `DEFAULT=YES` first.
    /// Falls back to the lowest-bandwidth `EXT-X-STREAM-INF` variant (muxed A/V).
    static func preferredAudioURL(master text: String, baseURL: URL) -> URL? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        struct Variant { let bandwidth: Int; let audioGroup: String?; let uri: String }
        struct Rendition { let group: String?; let isDefault: Bool; let uri: String }

        var variants: [Variant] = []
        var renditions: [Rendition] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if attrs["TYPE"]?.uppercased() == "AUDIO", let uri = attrs["URI"], !uri.isEmpty {
                    renditions.append(.init(group: attrs["GROUP-ID"], isDefault: attrs["DEFAULT"]?.uppercased() == "YES", uri: uri))
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                var j = i + 1
                while j < lines.count, lines[j].isEmpty || lines[j].hasPrefix("#") { j += 1 }
                if j < lines.count {
                    variants.append(.init(
                        bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? Int.max,
                        audioGroup: attrs["AUDIO"],
                        uri: lines[j]
                    ))
                    i = j
                }
            }
            i += 1
        }

        let lowest = variants.min { $0.bandwidth < $1.bandwidth }
        if !renditions.isEmpty {
            let inGroup = renditions.filter { lowest?.audioGroup == nil || $0.group == lowest?.audioGroup }
            let pool = inGroup.isEmpty ? renditions : inGroup
            let pick = pool.first(where: \.isDefault) ?? pool[0]
            if let url = URL(string: pick.uri, relativeTo: baseURL)?.absoluteURL { return url }
        }
        if let lowest, let url = URL(string: lowest.uri, relativeTo: baseURL)?.absoluteURL { return url }
        return nil
    }

    /// Strip the query (tokens / session ids) so a player-side token refresh on the same stream
    /// does not restart the caption pipeline.
    static func streamIdentity(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        c?.fragment = nil
        return c?.string ?? url.absoluteString
    }

    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        func commit() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k.uppercased()] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { commit() } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == ",", !quoted {
                commit()
            } else {
                value.append(ch)
            }
        }
        commit()
        return out
    }
}
