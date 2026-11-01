import Foundation

/// Paste-only stream URL helpers. Accepts rtmp(s) / http(s) HLS / plain http(s) media.
enum DirectStreamURL {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ raw: String) -> URL? {
        let s = normalize(raw)
        guard !s.isEmpty, let url = URL(string: s), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "rtmp", "rtmps", "http", "https":
            return url
        default:
            return nil
        }
    }

    static func needsFFmpeg(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "rtmp" || scheme == "rtmps"
    }

    /// Live caption demux works for HLS; RTMP-only is skipped with a tip (playback still works).
    static func supportsLiveCaption(_ url: URL) -> Bool {
        if needsFFmpeg(url) { return false }
        let path = url.path.lowercased()
        let abs = url.absoluteString.lowercased()
        return path.hasSuffix(".m3u8") || abs.contains(".m3u8")
    }

    static func isLikelyLive(_ url: URL) -> Bool {
        if needsFFmpeg(url) { return true }
        let abs = url.absoluteString.lowercased()
        return abs.contains(".m3u8") || abs.contains("/live/") || abs.contains("livestream")
    }

    static func displayTitle(_ url: URL) -> String {
        let last = url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !last.isEmpty, last.count <= 48, !last.contains(".") || last.lowercased().hasSuffix(".m3u8") {
            let bare = last.replacingOccurrences(of: ".m3u8", with: "", options: .caseInsensitive)
            if !bare.isEmpty { return bare }
        }
        if let host = url.host, !host.isEmpty { return host }
        return "打开地址"
    }

    static func schemeLabel(_ url: URL) -> String {
        let scheme = url.scheme?.uppercased() ?? "URL"
        if supportsLiveCaption(url) { return "HLS" }
        if needsFFmpeg(url) { return "RTMP" }
        return scheme
    }
}
