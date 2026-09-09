import Foundation
import UIKit
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

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
    /// 真实音频后台播放守护。录制下载与它处于同一进程生命周期。
    private let audioKeeper = BackgroundAudioKeeper()

    var activeUsernames: [String] { Array(sessions.keys).sorted() }
    var isAnyRecording: Bool { !sessions.isEmpty }

    func isRecording(_ username: String) -> Bool {
        sessions[username.lowercased()] != nil
    }

    func session(for username: String) -> RecordingSession? {
        sessions[username.lowercased()]
    }

    func start(username: String, videoPlaylist: URL, audioPlaylist: URL?, masterURL: URL) {
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
        // 优先播放独立音频 playlist，确保后台音频轨道真实存在。
        refreshIdle(masterURL: audioPlaylist ?? masterURL)
    }

    func stop(_ username: String) {
        sessions[username.lowercased()]?.stop(userInitiated: true)
    }

    func updateBackgroundAudio(url: URL) {
        guard isAnyRecording else { return }
        audioKeeper.update(url: url)
    }

    func keepBackgroundAlive() {
        guard isAnyRecording else { return }
        extendBackground()
        audioKeeper.recover(forceRebuild: false)
    }

    func toggle(username: String, videoPlaylist: URL, audioPlaylist: URL?, masterURL: URL) {
        if isRecording(username) {
            stop(username)
        } else {
            start(username: username, videoPlaylist: videoPlaylist, audioPlaylist: audioPlaylist, masterURL: masterURL)
        }
    }

    private func refreshIdle(masterURL: URL? = nil) {
        UIApplication.shared.isIdleTimerDisabled = isAnyRecording
        if isAnyRecording {
            extendBackground()
            if let masterURL { audioKeeper.start(url: masterURL) }
        } else {
            endBackground()
            audioKeeper.stop()
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

}

@MainActor
final class BackgroundAudioKeeper {
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var currentURL: URL?
    private var observers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var watchdog: Timer?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                      type == .ended else { return }
                self.recover(forceRebuild: false)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recover(forceRebuild: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recover(forceRebuild: false) }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start(url: URL) {
        if currentURL == url, player != nil { recover(forceRebuild: false); return }
        currentURL = url
        build(url: url)
        startWatchdog()
    }

    func update(url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        build(url: url)
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        statusObservation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil)
        player = nil; item = nil; currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    private func build(url: URL) {
        activateSession()
        statusObservation = nil
        player?.pause()
        let newItem = AVPlayerItem(url: url)
        newItem.preferredForwardBufferDuration = 3
        let newPlayer = AVPlayer(playerItem: newItem)
        newPlayer.volume = 0.01 // 非 0 才是有效后台音频渲染
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        item = newItem
        player = newPlayer
        statusObservation = newItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.recover(forceRebuild: true) }
        }
        newPlayer.play()
    }

    func recover(forceRebuild: Bool) {
        guard let url = currentURL else { return }
        activateSession()
        if forceRebuild || item?.status == .failed {
            build(url: url)
        } else if player?.timeControlStatus != .playing {
            player?.play()
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recover(forceRebuild: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
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
    @Published var phaseText = "录制中"

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
        // .part 目录只作为中间缓存，不出现在录像列表里。
        let dir = RecordingStore.directory.appendingPathComponent("\(username)_\(Self.stamp()).part", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        isRunning = true
        startTimer()

        let videoPL = videoPlaylist
        let audioPL = audioPlaylist
        let name = username
        let progress = self.progress
        workTask = Task.detached(priority: .utility) { [weak self] in
            let result = await HLSPackager.run(
                username: name,
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
        guard isRunning else { return }
        isRunning = false
        // URLSession.data(for:) 会因 Task cancellation 立即取消当前分片请求，
        // 不再等待 20 秒，随后 packager 写入 ENDLIST 并结束当前文件。
        progress.requestStop()
        workTask?.cancel()
    }

    private func finish(result: HLSPackager.Result, name: String, dir: URL) {
        stopTimer()
        isRunning = false
        tick()
        guard result.success, let index = result.indexURL,
              FileManager.default.fileExists(atPath: index.path) else {
            try? FileManager.default.removeItem(at: dir)
            onFinished?(name, "\(name) 录制失败：\(result.error ?? "未知")")
            return
        }

        let base = dir.lastPathComponent.hasSuffix(".part")
            ? String(dir.lastPathComponent.dropLast(5)) : dir.lastPathComponent
        let mp4 = dir.deletingLastPathComponent().appendingPathComponent(base + ".mp4")
        try? FileManager.default.removeItem(at: mp4)
        bannerMuxing(name)

        let duration = elapsedText
        let size = bytesText
        Task.detached(priority: .utility) { [weak self] in
            let ok = FFmpegLocalMuxer.mux(input: index, output: mp4)
            await MainActor.run {
                guard let self else { return }
                if ok, FileManager.default.fileExists(atPath: mp4.path) {
                    try? FileManager.default.removeItem(at: dir)
                    self.onFinished?(name, "\(name) 已保存 MP4 · \(duration) · \(size)")
                } else {
                    try? FileManager.default.removeItem(at: mp4)
                    self.onFinished?(name, "\(name) 封装 MP4 失败，中间文件已保留")
                }
            }
        }
    }

    private func bannerMuxing(_ name: String) {
        phaseText = "正在封装 MP4"
        RecordingManager.shared.banner = "\(name) 已停止，正在无损封装 MP4…"
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
    private var _lastChange = Date()

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

    var stalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastChange) > 8
    }

    func set(seconds: Double, bytes: Int64) {
        lock.lock()
        if seconds > _seconds + 0.2 || bytes > _bytes + 4096 {
            _lastChange = Date()
        }
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

enum FFmpegLocalMuxer {
    private static let lock = NSLock()

    private struct Timeline {
        var initialized = false
        var shift: Int64 = 0
        var lastDTS: Int64 = 0
        var lastDuration: Int64 = 1
    }

    static func mux(input: URL, output: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var inputContext: UnsafeMutablePointer<AVFormatContext>?
        var options: OpaquePointer?
        av_dict_set(&options, "allowed_extensions", "ALL", 0)
        av_dict_set(&options, "protocol_whitelist", "file,crypto,data,http,https,tcp,tls", 0)
        var result = avformat_open_input(&inputContext, input.path, nil, &options)
        av_dict_free(&options)
        guard result >= 0, let inputContext else { return false }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inputContext; avformat_close_input(&p) }
        result = avformat_find_stream_info(inputContext, nil)
        guard result >= 0 else { return false }

        try? FileManager.default.removeItem(at: output)
        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        result = avformat_alloc_output_context2(&outputContext, nil, "mp4", output.path)
        guard result >= 0, let outputContext else { return false }
        defer { avformat_free_context(outputContext) }

        var mapping = [Int: Int]()
        for i in 0..<Int(inputContext.pointee.nb_streams) {
            guard let source = inputContext.pointee.streams[i],
                  let codec = source.pointee.codecpar else { continue }
            let type = codec.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO,
                  let target = avformat_new_stream(outputContext, nil) else { continue }
            guard avcodec_parameters_copy(target.pointee.codecpar, codec) >= 0 else { continue }
            target.pointee.codecpar.pointee.codec_tag = 0
            target.pointee.time_base = source.pointee.time_base
            mapping[i] = Int(target.pointee.index)
        }
        guard !mapping.isEmpty else { return false }
        result = avio_open(&(outputContext.pointee.pb), output.path, AVIO_FLAG_WRITE)
        guard result >= 0 else { return false }
        defer { avio_closep(&(outputContext.pointee.pb)) }
        var muxOptions: OpaquePointer?
        av_dict_set(&muxOptions, "movflags", "+faststart", 0)
        result = avformat_write_header(outputContext, &muxOptions)
        av_dict_free(&muxOptions)
        guard result >= 0 else { return false }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var timelines = [Int: Timeline]()
        let noPTS = Int64.min
        while av_read_frame(inputContext, packet) >= 0 {
            guard let packet else { break }
            let sourceIndex = Int(packet.pointee.stream_index)
            guard let targetIndex = mapping[sourceIndex],
                  let source = inputContext.pointee.streams[sourceIndex],
                  let target = outputContext.pointee.streams[targetIndex] else {
                av_packet_unref(packet); continue
            }

            var timeline = timelines[sourceIndex] ?? Timeline()
            let rawDTS = packet.pointee.dts != noPTS ? packet.pointee.dts : packet.pointee.pts
            if rawDTS != noPTS {
                if !timeline.initialized {
                    timeline.initialized = true
                    timeline.shift = rawDTS
                }
                var normalized = rawDTS - timeline.shift
                if timeline.lastDTS > 0 {
                    let expected = timeline.lastDTS + max(timeline.lastDuration, 1)
                    let gap = normalized - expected
                    let threeSeconds = Int64(3) * Int64(source.pointee.time_base.den) /
                        Int64(max(source.pointee.time_base.num, 1))
                    if normalized < timeline.lastDTS || gap > max(threeSeconds, 1) {
                        // HLS discontinuity/锁屏恢复后压掉时间戳空洞。
                        timeline.shift += normalized - expected
                        normalized = expected
                    }
                }
                let delta = rawDTS - timeline.shift
                if packet.pointee.dts != noPTS { packet.pointee.dts = delta }
                if packet.pointee.pts != noPTS {
                    packet.pointee.pts = max(packet.pointee.pts - timeline.shift, delta)
                }
                timeline.lastDTS = delta
                if packet.pointee.duration > 0 { timeline.lastDuration = packet.pointee.duration }
                timelines[sourceIndex] = timeline
            }

            packet.pointee.stream_index = Int32(targetIndex)
            av_packet_rescale_ts(packet, source.pointee.time_base, target.pointee.time_base)
            packet.pointee.pos = -1
            if av_interleaved_write_frame(outputContext, packet) < 0 {
                av_packet_unref(packet); return false
            }
            av_packet_unref(packet)
        }
        guard av_write_trailer(outputContext) >= 0 else { return false }
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 1024
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
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 7_000_000_000)
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return first
        }
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
        let generation: Int
    }

    struct Parsed {
        var map: URL?
        var target: Int = 4
        var mediaSequence: Int = 0
        var segments: [Segment] = []
    }

    static func run(
        username: String,
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
            // playlist/session 失效后，同一次 resolve 同时更新音视频，避免轨道 session 不一致。
            group.addTask {
                var delay: UInt64 = 1_000_000_000
                var lastRefresh = Date()
                while !Task.isCancelled, !progress.stopping {
                    let dueRefresh = Date().timeIntervalSince(lastRefresh) > 480
                    if video.needsReconnect || (audio?.needsReconnect ?? false) || progress.stalled || dueRefresh {
                        do {
                            let fresh = try await StreamSource.resolve(username: username)
                            video.replacePlaylist(fresh.videoPlaylist)
                            if let audio, let freshAudio = fresh.audioPlaylist {
                                audio.replacePlaylist(freshAudio)
                            }
                            await MainActor.run {
                                RecordingManager.shared.updateBackgroundAudio(
                                    url: fresh.audioPlaylist ?? fresh.masterURL
                                )
                            }
                            delay = 1_000_000_000
                            lastRefresh = Date()
                        } catch {
                            try? await Task.sleep(nanoseconds: delay)
                            delay = min(delay * 2, 10_000_000_000)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            group.addTask {
                var lastKeepAlive = Date.distantPast
                while !Task.isCancelled {
                    progress.set(seconds: writer.videoDuration, bytes: writer.bytes)
                    writer.rewrite(ended: false)
                    if Date().timeIntervalSince(lastKeepAlive) > 20 {
                        lastKeepAlive = Date()
                        await MainActor.run { RecordingManager.shared.keepBackgroundAlive() }
                    }
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
            try? await Task.sleep(nanoseconds: 800_000_000)
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
                        track.complete(seq: seg.sequence, generation: seg.generation, data: data, duration: seg.duration)
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
        private var _playlist: URL
        let isAudio: Bool
        let writer: DiskWriter
        private let lock = NSLock()
        private var seen = Set<String>()
        private var queue: [Segment] = []
        private var ready: [Int: (Data, Double, Int)] = [:]
        private var nextWrite: Int?
        private var lastQueued = -1
        private var mapDone = false
        private var queuedCount = 0
        private var inflightCount = 0
        private var generation = 0
        private var consecutiveFailures = 0
        private var reconnectNeeded = false
        private var lastNewAt = Date()

        init(playlist: URL, isAudio: Bool, writer: DiskWriter) {
            self._playlist = playlist
            self.isAudio = isAudio
            self.writer = writer
        }

        var isIdle: Bool {
            lock.lock(); defer { lock.unlock() }
            return queue.isEmpty && inflightCount == 0 && ready.isEmpty
        }

        var needsReconnect: Bool {
            lock.lock(); defer { lock.unlock() }
            return reconnectNeeded
                || consecutiveFailures >= 3
                || Date().timeIntervalSince(lastNewAt) > 8
        }

        func replacePlaylist(_ url: URL) {
            lock.lock()
            generation += 1
            _playlist = url
            seen.removeAll()
            queue.removeAll()
            ready.removeAll()
            nextWrite = nil
            lastQueued = -1
            mapDone = false
            consecutiveFailures = 0
            reconnectNeeded = false
            lastNewAt = Date()
            lock.unlock()
            writer.markDiscontinuity(isAudio: isAudio)
        }

        func poll() async {
            lock.lock()
            let current = _playlist
            let gen = generation
            lock.unlock()
            do {
                let (data, http) = try await RecHLS.data(for: current)
                guard (200..<300).contains(http.statusCode),
                      let text = String(data: data, encoding: .utf8) else {
                    noteFailure(status: http.statusCode)
                    return
                }
                let parsed = HLSPackager.parse(text, base: current)
                guard !parsed.segments.isEmpty else { noteFailure(status: nil); return }
                noteSuccess()
                if !mapDone, let map = parsed.map {
                    if let chunk = await RecHLS.bytes(map), !chunk.isEmpty {
                        writer.writeInit(chunk, isAudio: isAudio)
                        lock.lock(); if generation == gen { mapDone = true }; lock.unlock()
                    }
                }
                enqueue(parsed.segments, generation: gen)
            } catch {
                noteFailure(status: nil)
            }
        }

        private func noteSuccess() {
            lock.lock(); consecutiveFailures = 0; lock.unlock()
        }

        private func noteFailure(status: Int?) {
            lock.lock()
            consecutiveFailures += 1
            if status == 401 || status == 403 || status == 404 || status == 410 {
                reconnectNeeded = true
            }
            lock.unlock()
        }

        func dequeue() -> Segment? {
            lock.lock(); defer { lock.unlock() }
            guard !queue.isEmpty else { return nil }
            let seg = queue.removeFirst()
            inflightCount += 1
            return seg
        }

        func complete(seq: Int, generation gen: Int, data: Data?, duration: Double) {
            lock.lock()
            inflightCount = max(0, inflightCount - 1)
            guard generation == gen else { lock.unlock(); return }
            if let data, !data.isEmpty {
                ready[seq] = (data, duration, gen)
            } else {
                ready[seq] = (Data(), duration, gen)
                consecutiveFailures += 1
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

        private func enqueue(_ segs: [Segment], generation gen: Int) {
            lock.lock()
            guard generation == gen else { lock.unlock(); return }
            var added = 0
            for raw in segs {
                let seg = Segment(duration: raw.duration, url: raw.url, sequence: raw.sequence, generation: gen)
                let key = seg.url.absoluteString
                if seen.contains(key) { continue }
                seen.insert(key)
                if lastQueued >= 0, seg.sequence > lastQueued + 1 {
                    writer.markDiscontinuity(isAudio: isAudio)
                }
                queue.append(seg)
                lastQueued = seg.sequence
                if nextWrite == nil { nextWrite = seg.sequence }
                added += 1
            }
            if added > 0 { lastNewAt = Date() }
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
                    out.segments.append(Segment(duration: pendingDuration, url: url, sequence: seq, generation: 0))
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
