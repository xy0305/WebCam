import Foundation
import Network

/// Stripchat 媒体清单用 `#EXT-X-MOUFLON:URI` 藏真实分片，公开 URI 是占位 `media.mp4`。
/// KSPlayer / FFmpeg 会忽略未知标签并卡住。这里把清单改写成标准 HLS，再经本地 HTTP 交给播放器刷新。
final class StripchatPlaylistProxy: @unchecked Sendable {
    static let shared = StripchatPlaylistProxy()

    private struct Source {
        var remote: URL
        var context: HLSRequestContext
        var keys: [String]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "camweb.stripchat.hls")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sources: [String: Source] = [:]
    private var startContinuations: [CheckedContinuation<Void, Error>] = []

    private init() {}

    func playbackURL(id: String, remote: URL, context: HLSRequestContext, keys: [String] = []) async throws -> URL {
        try await start()
        lock.lock()
        sources[id] = Source(remote: remote, context: context, keys: keys)
        let port = self.port
        lock.unlock()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/\(id).m3u8") else {
            throw StreamSourceError.badResponse
        }
        return url
    }

    private func start() async throws {
        lock.lock()
        if port > 0 {
            lock.unlock()
            return
        }
        if listener != nil {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                startContinuations.append(cont)
                lock.unlock()
            }
            return
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: 0)
        } catch {
            lock.unlock()
            throw error
        }
        self.listener = listener
        lock.unlock()

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            startContinuations.append(cont)
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.lock()
            if let value = listener?.port?.rawValue {
                port = value
            }
            let waiting = startContinuations
            startContinuations.removeAll()
            lock.unlock()
            waiting.forEach { $0.resume() }
        case .failed(let error):
            lock.lock()
            listener = nil
            port = 0
            let waiting = startContinuations
            startContinuations.removeAll()
            lock.unlock()
            waiting.forEach { $0.resume(throwing: error) }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let head = String(data: data, encoding: .utf8) ?? ""
            let path = Self.path(from: head)
            Task {
                await self.respond(connection, path: path)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) async {
        let id = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".m3u8", with: "")
        lock.lock()
        let source = sources[id]
        lock.unlock()
        guard let source else {
            send(connection, status: 404, body: Data("not found".utf8), type: "text/plain")
            return
        }
        do {
            let remote = try await fetchMedia(source)
            let rewritten = Self.rewrite(remote, base: source.remote)
            guard rewritten.contains("#EXTINF:"),
                  !rewritten.contains("media.mp4"),
                  !remote.contains("#EXT-X-MOUFLON-ADVERT") else {
                throw StreamSourceError.badResponse
            }
            send(connection, status: 200, body: Data(rewritten.utf8), type: "application/vnd.apple.mpegurl")
        } catch {
            send(connection, status: 502, body: Data("playlist error".utf8), type: "text/plain")
        }
    }

    private func fetchMedia(_ source: Source) async throws -> String {
        var urls: [URL] = [source.remote]
        for key in source.keys.reversed() {
            if let url = StripchatStreamSource.withPkey(source.remote, key: key),
               !urls.contains(url) {
                urls.insert(url, at: 0)
            }
        }
        var last: Error = StreamSourceError.badResponse
        for url in urls {
            do {
                let text = try await StripchatStreamSource.playlistText(url, context: source.context)
                if text.contains("#EXT-X-MOUFLON-ADVERT") { continue }
                if text.contains("#EXTINF:") { return text }
            } catch {
                last = error
            }
        }
        throw last
    }

    private func send(_ connection: NWConnection, status: Int, body: Data, type: String) {
        let reason = status == 200 ? "OK" : "Error"
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-cache, no-store, must-revalidate\r
        Connection: close\r
        \r
        """
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func path(from request: String) -> String {
        let first = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? request
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
    }

    static func rewrite(_ text: String, base: URL) -> String {
        var pending: String?
        var expectURI = false
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MOUFLON:URI:") {
                pending = abs(String(line.dropFirst("#EXT-X-MOUFLON:URI:".count)), base: base)
                continue
            }
            if line.hasPrefix("#EXT-X-MOUFLON") { continue }
            if line.hasPrefix("#EXT-X-PART") || line.hasPrefix("#EXT-X-PART-INF") ||
                line.hasPrefix("#EXT-X-PRELOAD-HINT") || line.hasPrefix("#EXT-X-SERVER-CONTROL") {
                pending = nil
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                lines.append(line.contains(",") ? line : line + ",")
                expectURI = true
                continue
            }
            if expectURI, !line.isEmpty, !line.hasPrefix("#") {
                let url = abs(pending ?? line, base: base)
                pending = nil
                expectURI = false
                if isPlaceholder(url) {
                    if lines.last?.hasPrefix("#EXTINF:") == true {
                        lines.removeLast()
                    }
                    continue
                }
                lines.append(url)
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                lines.append(absolutizeMap(line, base: base))
                continue
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }
        if lines.first != "#EXTM3U" {
            lines.insert("#EXTM3U", at: 0)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func abs(_ value: String, base: URL) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return text }
        return URL(string: text, relativeTo: base)?.absoluteString ?? text
    }

    private static func absolutizeMap(_ line: String, base: URL) -> String {
        guard let range = line.range(of: "URI=\"") else { return line }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return line }
        let raw = String(after[..<end])
        return line.replacingOccurrences(of: "URI=\"\(raw)\"", with: "URI=\"\(abs(raw, base: base))\"")
    }

    private static func isPlaceholder(_ url: String) -> Bool {
        let last = url.split(separator: "?").first.map(String.init)?.lowercased() ?? url.lowercased()
        return last.hasSuffix("/media.mp4") || last.hasSuffix("media.mp4")
    }
}
