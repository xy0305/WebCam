import Foundation
import Network

/// 只把媒体清单改成标准 HLS，经 127.0.0.1 交给 AVPlayer。
/// MAP / 分片改成绝对 CDN URL，由系统播放器直连（走 VPN）。
final class StripchatPlaylistProxy: @unchecked Sendable {
    static let shared = StripchatPlaylistProxy()

    private struct Source {
        var remote: URL
        var context: HLSRequestContext
        var keys: [String]
        var pdkey: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "camweb.stripchat.hls")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sources: [String: Source] = [:]
    private var startContinuations: [CheckedContinuation<Void, Error>] = []

    private init() {}

    func playbackURL(id: String, remote: URL, context: HLSRequestContext, keys: [String] = [], pdkey: String? = nil) async throws -> URL {
        try await start()
        lock.lock()
        sources[id] = Source(remote: remote, context: context, keys: keys, pdkey: pdkey)
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
        let id = path.split(separator: "/").first.map(String.init)?.replacingOccurrences(of: ".m3u8", with: "") ?? ""
        lock.lock()
        let source = sources[id]
        lock.unlock()
        guard let source else {
            send(connection, status: 404, body: Data("not found".utf8), type: "text/plain")
            return
        }
        do {
            let remote = try await fetchMedia(source)
            let rewritten = Self.rewrite(remote, base: source.remote, pdkey: source.pdkey)
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
        do {
            let text = try await StripchatStreamSource.playlistText(source.remote, context: source.context)
            if StripchatStreamSource.isPlayableMedia(text) { return text }
        } catch {}
        return try await StripchatStreamSource.mediaText(source.remote, keys: source.keys, context: source.context)
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

    static func rewrite(_ text: String, base: URL, pdkey: String?) -> String {
        var pending: String?
        var expectURI = false
        var activeKey = pdkey
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MOUFLON:PSCH:") {
                let pkey = line.split(separator: ":").last.map(String.init)
                if let found = StripchatMouflon.pdkey(for: pkey) { activeKey = found }
                continue
            }
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
                    if lines.last?.hasPrefix("#EXTINF:") == true { lines.removeLast() }
                    continue
                }
                lines.append(remoteMedia(url, base: base, pdkey: activeKey))
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                lines.append(remoteMap(line, base: base, pdkey: activeKey))
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

    private static func remoteMap(_ line: String, base: URL, pdkey: String?) -> String {
        guard let range = line.range(of: "URI=\"") else { return line }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return line }
        let raw = String(after[..<end])
        let remote = remoteMedia(raw, base: base, pdkey: pdkey)
        return line.replacingOccurrences(of: "URI=\"\(raw)\"", with: "URI=\"\(remote)\"")
    }

    private static func remoteMedia(_ raw: String, base: URL, pdkey: String?) -> String {
        let absolute = abs(raw, base: base)
        let decrypted = StripchatMouflon.decrypt(absolute, pdkey: pdkey)
        return encodedRemote(decrypted, base: base)?.absoluteString ?? decrypted
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
        if text.hasPrefix("//") { return "https:" + text }
        return URL(string: text, relativeTo: base)?.absoluteString ?? text
    }

    private static func isPlaceholder(_ url: String) -> Bool {
        let last = url.split(separator: "?").first.map(String.init)?.lowercased() ?? url.lowercased()
        return last.hasSuffix("/media.mp4") || last.hasSuffix("media.mp4")
    }
}
