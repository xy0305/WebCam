import Foundation
import UIKit
import AVFoundation
import FFmpegKit
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
    private var keepAlivePlayer: AVAudioPlayer?

    var activeUsernames: [String] { Array(sessions.keys).sorted() }
    var isAnyRecording: Bool { !sessions.isEmpty }

    func isRecording(_ username: String) -> Bool {
        sessions[username.lowercased()] != nil
    }

    func session(for username: String) -> RecordingSession? {
        sessions[username.lowercased()]
    }

    func start(username: String, hlsURL: URL, masterURL: URL) {
        let name = username.lowercased()
        guard sessions[name] == nil else { return }
        let session = RecordingSession(username: name, hlsURL: hlsURL, masterURL: masterURL)
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

    func toggle(username: String, hlsURL: URL, masterURL: URL) {
        if isRecording(username) {
            stop(username)
        } else {
            start(username: username, hlsURL: hlsURL, masterURL: masterURL)
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

/// 电脑端成熟方案：ffmpeg -c copy 录 HLS。
/// 这里用同一套 libavformat：打开迷你 master / 官方 master，按 packet copy 进 mp4。
@MainActor
final class RecordingSession: ObservableObject, Identifiable {
    var id: String { username }
    let username: String
    let hlsURL: URL
    let masterURL: URL

    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var isRunning = false

    var onFinished: ((String, String) -> Void)?

    private var timer: Timer?
    private var workTask: Task<Void, Never>?
    private let progress = RecProgress()

    init(username: String, hlsURL: URL, masterURL: URL) {
        self.username = username
        self.hlsURL = hlsURL
        self.masterURL = masterURL
    }

    func start() {
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(username)_\(Self.stamp()).mp4")

        isRunning = true
        startTimer()

        let hls = hlsURL
        let master = masterURL
        let name = username
        let progress = self.progress
        workTask = Task.detached(priority: .utility) { [weak self] in
            let result = FFmpegCopyRecorder.run(primary: hls, fallback: master, dest: dest, progress: progress)
            await MainActor.run {
                self?.finish(result: result, name: name, dest: dest)
            }
        }
    }

    func stop(userInitiated: Bool) {
        isRunning = false
        progress.requestStop()
    }

    private func finish(result: FFmpegCopyRecorder.Result, name: String, dest: URL) {
        stopTimer()
        isRunning = false
        tick()
        let msg: String
        if result.success, FileManager.default.fileExists(atPath: dest.path) {
            msg = "\(name) 已保存 \(elapsedText) · \(bytesText)"
        } else {
            try? FileManager.default.removeItem(at: dest)
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

enum FFmpegCopyRecorder {
    struct Result {
        let success: Bool
        let error: String?
    }

    static func run(primary: URL, fallback: URL, dest: URL, progress: RecProgress) -> Result {
        if let ok = copy(url: primary, dest: dest, progress: progress), ok.success {
            return ok
        }
        if fallback != primary, let ok = copy(url: fallback, dest: dest, progress: progress) {
            return ok
        }
        return Result(success: false, error: "打不开直播流")
    }

    private static func copy(url: URL, dest: URL, progress: RecProgress) -> Result? {
        avformat_network_init()

        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        var interruptOpaque = Unmanaged.passUnretained(progress).toOpaque()
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = interruptOpaque
        interruptCB.callback = { ctx in
            guard let ctx else { return 0 }
            let p = Unmanaged<RecProgress>.fromOpaque(ctx).takeUnretainedValue()
            return p.stopping ? 1 : 0
        }

        var opts = formatOptions()
        let urlString: String
        if url.isFileURL || url.scheme == "data" {
            urlString = url.absoluteString
        } else {
            urlString = url.absoluteString
        }
        var ret = avformat_open_input(&inCtx, urlString, nil, &opts)
        av_dict_free(&opts)
        guard ret == 0, let inCtx else {
            return nil
        }
        inCtx.pointee.interrupt_callback = interruptCB
        inCtx.pointee.flags |= AVFMT_FLAG_GENPTS
        ret = avformat_find_stream_info(inCtx, nil)
        guard ret >= 0 else {
            avformat_close_input(&inCtx)
            return nil
        }

        try? FileManager.default.removeItem(at: dest)
        let filename = dest.path
        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        ret = avformat_alloc_output_context2(&outCtx, nil, "mp4", filename)
        guard ret >= 0, let outCtx else {
            avformat_close_input(&inCtx)
            return Result(success: false, error: "无法创建 mp4")
        }

        var mapping = [Int: Int]()
        var outIndex = 0
        var audioTaken = false
        var videoTaken = false
        let nb = Int(inCtx.pointee.nb_streams)
        for i in 0..<nb {
            guard let inStream = inCtx.pointee.streams[i],
                  let codecpar = inStream.pointee.codecpar else { continue }
            let type = codecpar.pointee.codec_type
            if type == AVMEDIA_TYPE_AUDIO {
                if audioTaken { continue }
                audioTaken = true
            } else if type == AVMEDIA_TYPE_VIDEO {
                if videoTaken { continue }
                videoTaken = true
            } else {
                continue
            }
            guard let outStream = avformat_new_stream(outCtx, nil) else { continue }
            avcodec_parameters_copy(outStream.pointee.codecpar, codecpar)
            outStream.pointee.codecpar.pointee.codec_tag = 0
            mapping[i] = outIndex
            outIndex += 1
        }
        guard outIndex > 0 else {
            avformat_free_context(outCtx)
            avformat_close_input(&inCtx)
            return nil
        }

        ret = avio_open(&outCtx.pointee.pb, filename, AVIO_FLAG_WRITE)
        guard ret >= 0 else {
            avformat_free_context(outCtx)
            avformat_close_input(&inCtx)
            return Result(success: false, error: "无法写入文件")
        }
        ret = avformat_write_header(outCtx, nil)
        guard ret >= 0 else {
            avio_closep(&outCtx.pointee.pb)
            avformat_free_context(outCtx)
            avformat_close_input(&inCtx)
            return Result(success: false, error: "写文件头失败")
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        var firstPts: Int64?
        var lastBytes: Int64 = 0
        while !progress.stopping {
            ret = av_read_frame(inCtx, packet)
            if ret < 0 { break }
            defer { av_packet_unref(packet) }
            guard let pkt = packet else { continue }
            let inIndex = Int(pkt.pointee.stream_index)
            guard let mapped = mapping[inIndex],
                  let inStream = inCtx.pointee.streams[inIndex],
                  let outStream = outCtx.pointee.streams[mapped] else { continue }

            if firstPts == nil, pkt.pointee.pts != AV_NOPTS_VALUE {
                firstPts = pkt.pointee.pts
            }
            pkt.pointee.stream_index = Int32(mapped)
            av_packet_rescale_ts(pkt, inStream.pointee.time_base, outStream.pointee.time_base)
            pkt.pointee.pos = -1
            let w = av_interleaved_write_frame(outCtx, pkt)
            if w < 0 { break }

            let tb = inStream.pointee.time_base
            if let first = firstPts, pkt.pointee.dts != AV_NOPTS_VALUE {
                let pts = pkt.pointee.dts - first
                let sec = Double(pts) * Double(tb.num) / Double(max(tb.den, 1))
                if sec >= 0 {
                    let size = (try? FileManager.default.attributesOfItem(atPath: filename)[.size] as? Int64) ?? lastBytes
                    lastBytes = size
                    progress.set(seconds: sec, bytes: size)
                }
            }
        }

        av_write_trailer(outCtx)
        avio_closep(&outCtx.pointee.pb)
        avformat_free_context(outCtx)
        avformat_close_input(&inCtx)

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        progress.set(seconds: progress.seconds, bytes: size)
        guard size > 1024 else {
            return Result(success: false, error: "没有收到数据")
        }
        return Result(success: true, error: nil)
    }

    private static func formatOptions() -> OpaquePointer? {
        var opts: OpaquePointer?
        let ua = APIClient.userAgent
        av_dict_set(&opts, "user_agent", ua, 0)
        av_dict_set(&opts, "referer", "Referer: https://chaturbate.com/", 0)
        av_dict_set(&opts, "headers", "Referer: https://chaturbate.com/\r\nUser-Agent: \(ua)\r\n", 0)
        av_dict_set_int(&opts, "reconnect", 1, 0)
        av_dict_set_int(&opts, "reconnect_streamed", 1, 0)
        av_dict_set_int(&opts, "reconnect_delay_max", 4, 0)
        av_dict_set_int(&opts, "rw_timeout", 15_000_000, 0)
        av_dict_set_int(&opts, "timeout", 15_000_000, 0)
        av_dict_set_int(&opts, "http_persistent", 1, 0)
        av_dict_set_int(&opts, "seekable", 0, 0)
        av_dict_set(&opts, "allowed_extensions", "ALL", 0)
        av_dict_set(&opts, "protocol_whitelist", "file,http,https,tcp,tls,crypto,data", 0)
        return opts
    }
}
