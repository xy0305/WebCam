import Foundation

/// Stripchat 专用 HLS 请求器：与 Chaturbate 的 RecHLS 完全隔离，必须携带 Origin。
enum StripchatHLS {
    static func data(for url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue(APIClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://zh.stripchat.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://zh.stripchat.com", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func bytes(_ url: URL) async -> Data? {
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return nil }
            if let (data, response) = try? await data(for: url),
               (200..<300).contains(response.statusCode), !data.isEmpty { return data }
            try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 250_000_000))
        }
        return nil
    }
}

/// Stripchat 独立录制会话：直接保存其媒体 playlist，不参与 Chaturbate 重连/刷新规则。
/// 采用低并发顺序下载，适配 Stripchat LL-HLS 且降低设备发热。
@MainActor
final class StripchatRecordingSession: ObservableObject, Identifiable {
    var id: String { username }
    let username: String
    let playlist: URL
    let directory: URL
    private let progress: RecProgress
    private var task: Task<Void, Never>?
    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var isRunning = false
    @Published var phaseText = "录制中"
    var onFinished: ((String, String) -> Void)?

    init(username: String, playlist: URL, directory: URL, progress: RecProgress) {
        self.username = username; self.playlist = playlist; self.directory = directory; self.progress = progress
    }

    func start() {
        // 该 Task 继承 MainActor；网络 await 不阻塞界面，避免跨 actor 访问录制状态。
        task = Task { [weak self] in
            guard let self else { return }
            self.isRunning = true
            var seen = Set<String>()
            var entries: [(Double, String)] = []
            var index = 0
            let started = Date()
            while !Task.isCancelled && !self.progress.stopping {
                guard let (data, response) = try? await StripchatHLS.data(for: self.playlist),
                      (200..<300).contains(response.statusCode),
                      let text = String(data: data, encoding: .utf8) else {
                    try? await Task.sleep(nanoseconds: 1_500_000_000); continue
                }
                let parsed = self.parse(text, base: self.playlist)
                for item in parsed where seen.insert(item.url.absoluteString).inserted {
                    guard let chunk = await StripchatHLS.bytes(item.url) else { continue }
                    index += 1
                    let ext = chunk.first == 0x47 ? "ts" : "m4s"
                    let name = String(format: "sc-%05d.%@", index, ext)
                    try? chunk.write(to: self.directory.appendingPathComponent(name), options: .atomic)
                    entries.append((item.duration, name))
                    self.progress.set(seconds: Date().timeIntervalSince(started), bytes: Int64(entries.count))
                }
                self.writePlaylist(entries)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            self.writePlaylist(entries, ended: true)
            self.isRunning = false
            self.onFinished?(self.username, entries.isEmpty ? "\(self.username) Stripchat 未收到可录制分片" : "\(self.username) Stripchat 已保存恢复录像")
        }
    }

    func stop() { progress.requestStop() }

    private func parse(_ text: String, base: URL) -> [(duration: Double, url: URL)] {
        var result: [(Double, URL)] = []; var duration = 2.0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:"), let value = line.dropFirst(8).split(separator: ",").first { duration = Double(value) ?? 2 }
            else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL { result.append((duration, url)) }
        }
        return result
    }

    private func writePlaylist(_ entries: [(Double, String)], ended: Bool = false) {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:\(ended ? "VOD" : "EVENT")\n"
        for (duration, name) in entries { text += String(format: "#EXTINF:%.3f,\n%@\n", duration, name) }
        if ended { text += "#EXT-X-ENDLIST\n" }
        try? text.write(to: directory.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    }
}
