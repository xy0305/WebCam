import Foundation
import Network

/// Stripchat 媒体清单用 `#EXT-X-MOUFLON:URI` 藏真实分片，公开 URI 是占位 `media.mp4`。
/// KSPlayer 会忽略未知标签，且分片路径里的 `+` `/` 会被拆错。
/// 这里把清单改成标准 HLS，并把 MAP/分片都走 127.0.0.1，由我们带 Referer 去拉。
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
            listener = try Self.makeListener()
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

    private static func makeListener() throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        do {
            return try NWListener(using: params)
        } catch {
            return try NWListener(using: .tcp, on: 18_765)
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.lock()
            if let value = listener?.port?.rawValue, value > 0 {
                port = value
            } else {
                port = 18_765
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
        readHeader(connection, buffer: Data())
    }

    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                Task { await self.respond(connection, path: Self.path(from: head)) }
                return
            }
            if complete || buf.count > 32 * 1024 {
                connection.cancel()
                return
            }
            self.readHeader(connection, buffer: buf)
        }
    }

    private func respond(_ connection: NWConnection, path: String) async {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[1] == "m" {
            await sendSegment(connection, id: parts[0], token: parts[2])
            return
        }
        let id = parts.first?.replacingOccurrences(of: ".m3u8", with: "") ?? ""
        lock.lock()
        let source = sources[id]
        let port = self.port
        lock.unlock()
        guard let source, port > 0 else {
            send(connection, status: 404, body: Data("not found".utf8), type: "text/plain")
            return
        }
        do {
            let remote = try await fetchMedia(source)
            let local = URL(string: "http://127.0.0.1:\(port)")!
            let rewritten = Self.rewrite(remote, base: source.remote, local: local, id: id)
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

    private func sendSegment(_ connection: NWConnection, id: String, token: String) async {
        lock.lock()
        let source = sources[id]
        lock.unlock()
        guard let source, let raw = Self.detokenize(token),
              let url = Self.encodedRemote(raw, base: source.remote) else {
            send(connection, status: 404, body: Data("bad segment".utf8), type: "text/plain")
            return
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue(APIClient.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            req.setValue(source.context.referer, forHTTPHeaderField: "Referer")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                throw StreamSourceError.badResponse
            }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
            send(connection, status: 200, body: data, type: type)
        } catch {
            send(connection, status: 502, body: Data("segment error".utf8), type: "text/plain")
        }
    }

    private func fetchMedia(_ source: Source) async throws -> String {
        var urls: [URL] = []
        for key in source.keys.reversed() {
            if let url = StripchatStreamSource.withPkey(source.remote, key: key),
               !urls.contains(url) {
                urls.append(url)
            }
        }
        if !urls.contains(source.remote) { urls.append(source.remote) }
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
        Access-Control-Allow-Origin: *\r
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

    static func rewrite(_ text: String, base: URL, local: URL, id: String) -> String {
        var pending: String?
        var expectURI = false
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MOUFLON:URI:") {
                pending = String(line.dropFirst("#EXT-X-MOUFLON:URI:".count))
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
                let url = pending ?? line
                pending = nil
                expectURI = false
                if isPlaceholder(url) {
                    if lines.last?.hasPrefix("#EXTINF:") == true {
                        lines.removeLast()
                    }
                    continue
                }
                lines.append(localMedia(url, base: base, local: local, id: id))
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                lines.append(localMap(line, base: base, local: local, id: id))
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

    private static func localMap(_ line: String, base: URL, local: URL, id: String) -> String {
        guard let range = line.range(of: "URI=\"") else { return line }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return line }
        let raw = String(after[..<end])
        let localURL = localMedia(raw, base: base, local: local, id: id)
        return line.replacingOccurrences(of: "URI=\"\(raw)\"", with: "URI=\"\(localURL)\"")
    }

    private static func localMedia(_ raw: String, base: URL, local: URL, id: String) -> String {
        let abs = Self.abs(raw, base: base)
        return "\(local.absoluteString)/\(id)/m/\(token(for: abs))"
    }

    static func encodedRemote(_ raw: String, base: URL) -> URL? {
        let absolute = abs(raw, base: base)
        guard let schemeEnd = absolute.range(of: "://") else { return URL(string: absolute) }
        guard let pathStart = absolute[schemeEnd.upperBound...].firstIndex(of: "/") else {
            return URL(string: absolute)
        }
        let origin = String(absolute[..<pathStart])
        var rest = String(absolute[pathStart...])
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[q...])
            rest = String(rest[..<q])
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 3 else {
            return URL(string: origin + rest.replacingOccurrences(of: "+", with: "%2B") + query)
        }
        let head = parts.prefix(3).joined(separator: "/")
        let tail = parts.dropFirst(3).joined(separator: "/")
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
        return URL(string: origin + head + "/" + tail + query)
    }

    private static func abs(_ value: String, base: URL) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return text }
        return URL(string: text, relativeTo: base)?.absoluteString ?? text
    }

    private static func isPlaceholder(_ url: String) -> Bool {
        let last = url.split(separator: "?").first.map(String.init)?.lowercased() ?? url.lowercased()
        return last.hasSuffix("/media.mp4") || last.hasSuffix("media.mp4")
    }

    private static func token(for url: String) -> String {
        Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func detokenize(_ token: String) -> String? {
        var text = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
