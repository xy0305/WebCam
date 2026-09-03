import Foundation
import UIKit
import AVFoundation

@MainActor
final class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    @Published private(set) var sessions: [String: RecordingSession] = [:]
    @Published var banner: String?
    @Published var libraryRevision = 0

    func noteLibraryChanged() {
        libraryRevision += 1
    }

    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var keepAlivePlayer: AVAudioPlayer?

    var activeUsernames: [String] { Array(sessions.keys).sorted() }
    var isAnyRecording: Bool { !sessions.isEmpty }

    func isRecording(_ username: String) -> Bool {
        sessions[username.lowercased()] != nil
    }

    func session(for username: String) -> RecordingSession? {
        sessions[username.lowercased()]
    }

    func start(username: String, videoPlaylist: URL, audioPlaylist: URL?) {
        let name = username.lowercased()
        guard sessions[name] == nil else { return }
        let session = RecordingSession(username: name, videoPlaylist: videoPlaylist, audioPlaylist: audioPlaylist)
        session.onFinished = { [weak self] name, message in
            self?.sessions[name] = nil
            self?.banner = message
            self?.libraryRevision += 1
            self?.refreshIdle()
        }
        sessions[name] = session
        session.start()
        refreshIdle()
    }

    func stop(_ username: String) {
        sessions[username.lowercased()]?.stop(userInitiated: true)
    }

    func toggle(username: String, videoPlaylist: URL, audioPlaylist: URL?) {
        if isRecording(username) {
            stop(username)
        } else {
            start(username: username, videoPlaylist: videoPlaylist, audioPlaylist: audioPlaylist)
        }
    }

    private func refreshIdle() {
        UIApplication.shared.isIdleTimerDisabled = isAnyRecording
        if isAnyRecording {
            extendBackground()
            startKeepAliveAudio()
        } else {
            endBackground()
            stopKeepAliveAudio()
        }
    }

    private func extendBackground() {
        endBackground()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "hls-record") { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func startKeepAliveAudio() {
        guard keepAlivePlayer == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if let url = Self.silentWavURL(),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
            keepAlivePlayer = player
        }
    }

    private func stopKeepAliveAudio() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }

    private static func silentWavURL() -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("camweb-keepalive.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func le32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let sampleRate: UInt32 = 8000
        let samples: UInt32 = 800
        ascii("RIFF"); le32(36 + samples * 2); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1); le16(1); le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        ascii("data"); le32(samples * 2)
        data.append(Data(count: Int(samples * 2)))
        try? data.write(to: url)
        return url
    }
}

/// 把直播媒体 playlist 存成本地 HLS VOD。
@MainActor
final class RecordingSession: ObservableObject, Identifiable {
    var id: String { username }
    let username: String
    let videoPlaylist: URL
    let audioPlaylist: URL?

    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var isRunning = false

    var onFinished: ((String, String) -> Void)?

    private var timer: Timer?
    private var workTask: Task<Void, Never>?
    private let progress = RecProgress()

    init(username: String, videoPlaylist: URL, audioPlaylist: URL?) {
        self.username = username
        self.videoPlaylist = videoPlaylist
        self.audioPlaylist = audioPlaylist
    }

    func start() {
        let dir = RecordingStore.directory.appendingPathComponent("\(username)_\(Self.stamp())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        isRunning = true
        startTimer()

        let videoPL = videoPlaylist
        let audioPL = audioPlaylist
        let name = username
        let progress = self.progress
        workTask = Task.detached(priority: .utility) { [weak self] in
            let result = await HLSPackager.run(
                videoPlaylist: videoPL,
                audioPlaylist: audioPL,
                dir: dir,
                progress: progress
            )
            await MainActor.run {
                self?.finish(result: result, name: name, dir: dir)
            }
        }
    }

    func stop(userInitiated: Bool) {
        isRunning = false
        // 先停轮询，把已经出现的分片下完，再收尾。不要立刻 cancel。
        progress.requestStop()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.workTask?.cancel()
        }
    }

    private func finish(result: HLSPackager.Result, name: String, dir: URL) {
        stopTimer()
        isRunning = false
        tick()
        let msg: String
        if result.success, let url = result.indexURL, FileManager.default.fileExists(atPath: url.path) {
            msg = "\(name) 已保存 \(elapsedText) · \(bytesText)"
        } else {
            try? FileManager.default.removeItem(at: dir)
            msg = "\(name) 录制失败：\(result.error ?? "未知")"
        }
        onFinished?(name, msg)
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        elapsedText = Self.clock(progress.seconds)
        bytesText = String(format: "%.1f MB", Double(progress.bytes) / 1_048_576)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}

final class RecProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _seconds: Double = 0
    private var _bytes: Int64 = 0
    private var _stopping = false

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return _seconds
    }

    var bytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _bytes
    }

    var stopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopping
    }

    func set(seconds: Double, bytes: Int64) {
        lock.lock()
        _seconds = seconds
        _bytes = bytes
        lock.unlock()
    }

    func requestStop() {
        lock.lock()
        _stopping = true
        lock.unlock()
    }
}

enum RecHLS {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 10
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = APIClient.hlsHeaders
        return URLSession(configuration: c)
    }()

    static func data(for url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 6
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func bytes(_ url: URL) async -> Data? {
        for attempt in 0..<5 {
            if Task.isCancelled { return nil }
            do {
                let (data, http) = try await data(for: url)
                if http.statusCode == 404 || http.statusCode == 410 { return nil }
                if (200..<300).contains(http.statusCode), !data.isEmpty { return data }
            } catch {
                if error is CancellationError { return nil }
            }
            try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 80_000_000))
        }
        return nil
    }
}

enum HLSPackager {
    struct Result {
        let success: Bool
        let indexURL: URL?
        let error: String?
    }

    struct Segment {
        let duration: Double
        let url: URL
        let sequence: Int
    }

    struct Parsed {
        var map: URL?
        var target: Int = 4
        var mediaSequence: Int = 0
        var segments: [Segment] = []
    }

    static func run(
        videoPlaylist: URL,
        audioPlaylist: URL?,
        dir: URL,
        progress: RecProgress
    ) async -> Result {
        let writer = DiskWriter(dir: dir)
        let video = Track(playlist: videoPlaylist, isAudio: false, writer: writer)
        let audio = audioPlaylist.map { Track(playlist: $0, isAudio: true, writer: writer) }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pollLoop(video, progress: progress) }
            group.addTask { await downloadLoop(video, progress: progress) }
            if let audio {
                group.addTask { await pollLoop(audio, progress: progress) }
                group.addTask { await downloadLoop(audio, progress: progress) }
            }
            group.addTask {
                while !Task.isCancelled {
                    progress.set(seconds: writer.videoDuration, bytes: writer.bytes)
                    writer.rewrite(ended: false)
                    if progress.stopping, video.isIdle, audio?.isIdle ?? true { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        video.flushGaps()
        audio?.flushGaps()
        writer.rewrite(ended: true)
        progress.set(seconds: writer.videoDuration, bytes: writer.bytes)
        guard writer.videoDuration > 0.5, writer.bytes > 1024 else {
            return Result(success: false, indexURL: nil, error: "没有收到视频分片")
        }
        return Result(success: true, indexURL: writer.indexURL, error: nil)
    }

    private static func pollLoop(_ track: Track, progress: RecProgress) async {
        while !Task.isCancelled {
            await track.poll()
            if progress.stopping { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await track.poll()
    }

    private static func downloadLoop(_ track: Track, progress: RecProgress) async {
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            while !Task.isCancelled {
                while inflight < 6, let seg = track.dequeue() {
                    inflight += 1
                    group.addTask {
                        let data = await RecHLS.bytes(seg.url)
                        track.complete(seq: seg.sequence, data: data, duration: seg.duration)
                    }
                }
                if progress.stopping, track.isIdle, inflight == 0 { break }
                if inflight == 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    continue
                }
                await group.next()
                inflight -= 1
            }
        }
    }

    final class Track: @unchecked Sendable {
        let playlist: URL
        let isAudio: Bool
        let writer: DiskWriter
        private let lock = NSLock()
        private var seen = Set<String>()
        private var queue: [Segment] = []
        private var ready: [Int: (Data, Double)] = [:]
        private var nextWrite: Int?
        private var lastQueued = -1
        private var mapDone = false
        private var queuedCount = 0
        private var inflightCount = 0

        init(playlist: URL, isAudio: Bool, writer: DiskWriter) {
            self.playlist = playlist
            self.isAudio = isAudio
            self.writer = writer
        }

        var isIdle: Bool {
            lock.lock(); defer { lock.unlock() }
            return queue.isEmpty && inflightCount == 0 && ready.isEmpty
        }

        func poll() async {
            do {
                let (data, http) = try await RecHLS.data(for: playlist)
                guard (200..<300).contains(http.statusCode),
                      let text = String(data: data, encoding: .utf8) else { return }
                let parsed = HLSPackager.parse(text, base: playlist)
                if !mapDone, let map = parsed.map {
                    if let chunk = await RecHLS.bytes(map), !chunk.isEmpty {
                        writer.writeInit(chunk, isAudio: isAudio)
                        mapDone = true
                    }
                }
                enqueue(parsed.segments)
            } catch {
            }
        }

        func dequeue() -> Segment? {
            lock.lock(); defer { lock.unlock() }
            guard !queue.isEmpty else { return nil }
            let seg = queue.removeFirst()
            inflightCount += 1
            return seg
        }

        func complete(seq: Int, data: Data?, duration: Double) {
            lock.lock()
            inflightCount = max(0, inflightCount - 1)
            if let data, !data.isEmpty {
                ready[seq] = (data, duration)
            } else {
                ready[seq] = (Data(), duration)
            }
            flushLocked()
            lock.unlock()
        }

        func flushGaps() {
            lock.lock()
            while let next = nextWrite, ready[next] == nil, ready.keys.contains(where: { $0 > next }) {
                writer.markDiscontinuity(isAudio: isAudio)
                nextWrite = next + 1
            }
            flushLocked()
            lock.unlock()
        }

        private func enqueue(_ segs: [Segment]) {
            lock.lock()
            for seg in segs {
                let key = seg.url.absoluteString
                if seen.contains(key) { continue }
                seen.insert(key)
                if lastQueued >= 0, seg.sequence > lastQueued + 1 {
                    writer.markDiscontinuity(isAudio: isAudio)
                }
                queue.append(seg)
                lastQueued = seg.sequence
                if nextWrite == nil { nextWrite = seg.sequence }
            }
            lock.unlock()
        }

        private func flushLocked() {
            while let next = nextWrite, let item = ready.removeValue(forKey: next) {
                if item.0.isEmpty {
                    writer.markDiscontinuity(isAudio: isAudio)
                } else {
                    writer.append(item.0, duration: item.1, isAudio: isAudio)
                }
                nextWrite = next + 1
            }
        }
    }

    static func parse(_ doc: String, base: URL) -> Parsed {
        var out = Parsed()
        var expectURI = false
        var pendingDuration: Double = 2
        var seq = 0
        let lines = doc.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                out.target = Int(line.split(separator: ":").last ?? "4") ?? 4
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                seq = Int(line.split(separator: ":").last ?? "0") ?? 0
                out.mediaSequence = seq
            } else if line.hasPrefix("#EXT-X-MAP:") {
                out.map = extractURI(line, base: base)
            } else if line.hasPrefix("#EXTINF:") {
                let raw = line.dropFirst("#EXTINF:".count)
                let num = raw.split(separator: ",").first.map(String.init) ?? "2"
                pendingDuration = Double(num) ?? 2
                expectURI = true
            } else if expectURI && !line.isEmpty && !line.hasPrefix("#") {
                if let url = resolve(line, base: base) {
                    out.segments.append(Segment(duration: pendingDuration, url: url, sequence: seq))
                    seq += 1
                }
                expectURI = false
            }
        }
        if out.target < 1 { out.target = 4 }
        return out
    }

    private static func extractURI(_ line: String, base: URL) -> URL? {
        if let r = line.range(of: "URI=\"") {
            let after = line[r.upperBound...]
            if let end = after.firstIndex(of: "\"") {
                return resolve(String(after[..<end]), base: base)
            }
        }
        if let r = line.range(of: "URI=") {
            let after = line[r.upperBound...]
            let raw = after.split(separator: ",").first.map(String.init) ?? String(after)
            return resolve(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), base: base)
        }
        return nil
    }

    private static func resolve(_ str: String, base: URL) -> URL? {
        if str.hasPrefix("http://") || str.hasPrefix("https://") { return URL(string: str) }
        return URL(string: str, relativeTo: base)?.absoluteURL
    }

    final class DiskWriter: @unchecked Sendable {
        let dir: URL
        let indexURL: URL
        private let lock = NSLock()
        private var vInit: String?
        private var aInit: String?
        private var vItems: [Item] = []
        private var aItems: [Item] = []
        private var pendingVDisc = false
        private var pendingADisc = false
        private var vIndex = 0
        private var aIndex = 0
        private var _bytes: Int64 = 0
        private var _vDuration: Double = 0
        private var vTarget = 4
        private var aTarget = 4

        struct Item {
            var discontinuity: Bool
            var duration: Double
            var name: String
        }

        init(dir: URL) {
            self.dir = dir
            self.indexURL = dir.appendingPathComponent("index.m3u8")
        }

        var bytes: Int64 {
            lock.lock(); defer { lock.unlock() }
            return _bytes
        }

        var videoDuration: Double {
            lock.lock(); defer { lock.unlock() }
            return _vDuration
        }

        func writeInit(_ data: Data, isAudio: Bool) {
            lock.lock()
            let name = isAudio ? "a-init.mp4" : "v-init.mp4"
            writeFile(name, data: data)
            if isAudio { aInit = name } else { vInit = name }
            lock.unlock()
        }

        func markDiscontinuity(isAudio: Bool) {
            lock.lock()
            if isAudio { pendingADisc = true } else { pendingVDisc = true }
            lock.unlock()
        }

        func append(_ data: Data, duration: Double, isAudio: Bool) {
            lock.lock()
            let ext = data.first == 0x47 ? "ts" : "m4s"
            if isAudio {
                aIndex += 1
                let name = String(format: "a-%05d.%@", aIndex, ext)
                writeFile(name, data: data)
                aItems.append(Item(discontinuity: pendingADisc, duration: duration, name: name))
                pendingADisc = false
                aTarget = max(aTarget, Int(duration.rounded(.up)))
            } else {
                vIndex += 1
                let name = String(format: "v-%05d.%@", vIndex, ext)
                writeFile(name, data: data)
                vItems.append(Item(discontinuity: pendingVDisc, duration: duration, name: name))
                pendingVDisc = false
                _vDuration += duration
                vTarget = max(vTarget, Int(duration.rounded(.up)))
            }
            lock.unlock()
        }

        func rewrite(ended: Bool) {
            lock.lock()
            let vBody = playlist(initName: vInit, items: vItems, target: vTarget, ended: ended)
            writeText("video.m3u8", vBody)
            if !aItems.isEmpty || aInit != nil {
                let aBody = playlist(initName: aInit, items: aItems, target: aTarget, ended: ended)
                writeText("audio.m3u8", aBody)
                writeText("index.m3u8", """
                #EXTM3U
                #EXT-X-INDEPENDENT-SEGMENTS
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO="aud"
                video.m3u8

                """)
            } else {
                writeText("index.m3u8", """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=5000000
                video.m3u8

                """)
            }
            lock.unlock()
        }

        private func playlist(initName: String?, items: [Item], target: Int, ended: Bool) -> String {
            let version = initName == nil ? 3 : 7
            var s = "#EXTM3U\n#EXT-X-VERSION:\(version)\n#EXT-X-TARGETDURATION:\(max(target, 1))\n"
            s += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:\(ended ? "VOD" : "EVENT")\n"
            if let initName {
                s += "#EXT-X-MAP:URI=\"\(initName)\"\n"
            }
            for item in items {
                if item.discontinuity { s += "#EXT-X-DISCONTINUITY\n" }
                s += String(format: "#EXTINF:%.3f,\n%@\n", item.duration, item.name)
            }
            if ended { s += "#EXT-X-ENDLIST\n" }
            return s
        }

        private func writeFile(_ name: String, data: Data) {
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url, options: .atomic)
            _bytes += Int64(data.count)
        }

        private func writeText(_ name: String, _ text: String) {
            try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
    }
}
