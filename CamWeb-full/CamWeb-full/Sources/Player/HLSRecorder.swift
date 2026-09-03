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

    /// iOS 后台网络会被掐，靠 UIBackgroundModes=audio + 静音循环把进程保住。
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

/// 把直播媒体 playlist 存成本地 HLS VOD（init + 分片 + m3u8）。
/// 不再把 fMP4 碎片拼成一个 mp4：AVPlayer 只会播到时间戳断掉的地方，十几分钟会变成几分钟。
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
        workTask?.cancel()
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

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return _seconds
    }

    var bytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _bytes
    }

    func set(seconds: Double, bytes: Int64) {
        lock.lock()
        _seconds = seconds
        _bytes = bytes
        lock.unlock()
    }
}

enum HLSPackager {
    struct Result {
        let success: Bool
        let indexURL: URL?
        let error: String?
    }

    private struct Segment {
        let duration: Double
        let url: URL
        let sequence: Int
    }

    private struct Parsed {
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
        var videoSeen = Set<String>()
        var audioSeen = Set<String>()
        var videoMapDone = false
        var audioMapDone = false
        var nextVideoSeq = 0
        var nextAudioSeq = 0

        while !Task.isCancelled {
            do {
                try await pull(
                    playlist: videoPlaylist,
                    seen: &videoSeen,
                    mapDone: &videoMapDone,
                    nextSeq: &nextVideoSeq,
                    isAudio: false,
                    writer: writer
                )
                if let audio = audioPlaylist {
                    try await pull(
                        playlist: audio,
                        seen: &audioSeen,
                        mapDone: &audioMapDone,
                        nextSeq: &nextAudioSeq,
                        isAudio: true,
                        writer: writer
                    )
                }
                progress.set(seconds: writer.videoDuration, bytes: writer.bytes)
                writer.rewrite(ended: false)
            } catch is CancellationError {
                break
            } catch {
                // 单次失败不中断
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        writer.rewrite(ended: true)
        progress.set(seconds: writer.videoDuration, bytes: writer.bytes)
        guard writer.videoDuration > 0.5, writer.bytes > 1024 else {
            return Result(success: false, indexURL: nil, error: "没有收到视频分片")
        }
        return Result(success: true, indexURL: writer.indexURL, error: nil)
    }

    private static func pull(
        playlist: URL,
        seen: inout Set<String>,
        mapDone: inout Bool,
        nextSeq: inout Int,
        isAudio: Bool,
        writer: DiskWriter
    ) async throws {
        let (data, http) = try await APIClient.hlsData(for: playlist, retry: 0)
        guard (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return }
        let parsed = parse(text, base: playlist)

        if !mapDone, let map = parsed.map {
            let chunk = try await fetchBytes(map)
            writer.writeInit(chunk, isAudio: isAudio)
            mapDone = true
        }

        for seg in parsed.segments {
            let key = seg.url.absoluteString
            if seen.contains(key) { continue }
            if nextSeq > 0, seg.sequence > nextSeq {
                writer.markDiscontinuity(isAudio: isAudio)
            }
            do {
                let chunk = try await fetchBytes(seg.url)
                guard !chunk.isEmpty else { continue }
                writer.append(chunk, duration: seg.duration, isAudio: isAudio)
                seen.insert(key)
                nextSeq = seg.sequence + 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 这一片下次再试，避免窗口滑走后永远缺一段
                break
            }
        }
    }

    private static func parse(_ doc: String, base: URL) -> Parsed {
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

    private static func fetchBytes(_ url: URL) async throws -> Data {
        let (data, http) = try await APIClient.hlsData(for: url, retry: 1)
        guard (200..<300).contains(http.statusCode) else {
            throw StreamSourceError.httpStatus(http.statusCode)
        }
        return data
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
