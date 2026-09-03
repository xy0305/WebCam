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

    func start(username: String, videoPlaylist: URL, audioPlaylist: URL?, masterURL: URL) {
        let name = username.lowercased()
        guard sessions[name] == nil else { return }
        let session = RecordingSession(
            username: name,
            videoPlaylist: videoPlaylist,
            audioPlaylist: audioPlaylist,
            masterURL: masterURL
        )
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

    func toggle(username: String, videoPlaylist: URL, audioPlaylist: URL?, masterURL: URL) {
        if isRecording(username) {
            stop(username)
        } else {
            start(username: username, videoPlaylist: videoPlaylist, audioPlaylist: audioPlaylist, masterURL: masterURL)
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

/// ffmpeg -c copy：先写本地迷你 master（电脑端 streamlink 同款），再打开 copy 进 mp4。
@MainActor
final class RecordingSession: ObservableObject, Identifiable {
    var id: String { username }
    let username: String
    let videoPlaylist: URL
    let audioPlaylist: URL?
    let masterURL: URL

    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var isRunning = false

    var onFinished: ((String, String) -> Void)?

    private var timer: Timer?
    private var workTask: Task<Void, Never>?
    private let progress = RecProgress()

    init(username: String, videoPlaylist: URL, audioPlaylist: URL?, masterURL: URL) {
        self.username = username
        self.videoPlaylist = videoPlaylist
        self.audioPlaylist = audioPlaylist
        self.masterURL = masterURL
    }

    func start() {
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(username)_\(Self.stamp()).mp4")
        let local = MiniMasterFile.write(video: videoPlaylist, audio: audioPlaylist)

        isRunning = true
        startTimer()

        var urls = [local, videoPlaylist, masterURL]
        var seen = Set<String>()
        urls = urls.filter { seen.insert($0.absoluteString).inserted }

        let name = username
        let progress = self.progress
        workTask = Task.detached(priority: .utility) { [weak self] in
            let result = FFmpegCopyRecorder.run(urls: urls, dest: dest, progress: progress)
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

enum MiniMasterFile {
    static func write(video: URL, audio: URL?) -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("camweb-\(UUID().uuidString).m3u8")
        let body: String
        if let audio {
            body = """
            #EXTM3U
            #EXT-X-VERSION:6
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audio.absoluteString)"
            #EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO="aud"
            \(video.absoluteString)

            """
        } else {
            body = """
            #EXTM3U
            #EXT-X-VERSION:6
            #EXT-X-STREAM-INF:BANDWIDTH=8000000
            \(video.absoluteString)

            """
        }
        try? body.data(using: .utf8)?.write(to: tmp)
        return tmp
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

    static func run(urls: [URL], dest: URL, progress: RecProgress) -> Result {
        var last = "打不开直播流"
        for url in urls {
            let r = copy(url: url, dest: dest, progress: progress)
            if r.success { return r }
            if let e = r.error, !e.isEmpty { last = e }
            if progress.stopping { break }
        }
        return Result(success: false, error: last)
    }

    private static func avErr(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buf, buf.count)
        let s = String(cString: buf)
        return s.isEmpty ? "err \(code)" : s
    }

    private static func copy(url: URL, dest: URL, progress: RecProgress) -> Result {
        avformat_network_init()

        var inCtx = avformat_alloc_context()
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = Unmanaged.passUnretained(progress).toOpaque()
        interruptCB.callback = { ctx in
            guard let ctx else { return 0 }
            let p = Unmanaged<RecProgress>.fromOpaque(ctx).takeUnretainedValue()
            return p.stopping ? 1 : 0
        }
        inCtx?.pointee.interrupt_callback = interruptCB

        var opts = formatOptions()
        let urlString = url.isFileURL ? url.path : url.absoluteString
        var ret = avformat_open_input(&inCtx, urlString, nil, &opts)
        av_dict_free(&opts)
        guard ret == 0, inCtx != nil else {
            return Result(success: false, error: "打开失败 \(avErr(ret))")
        }
        inCtx?.pointee.flags |= AVFMT_FLAG_GENPTS
        inCtx?.pointee.probesize = 5_000_000
        inCtx?.pointee.max_analyze_duration = 5_000_000
        ret = avformat_find_stream_info(inCtx, nil)
        guard ret >= 0, let input = inCtx else {
            avformat_close_input(&inCtx)
            return Result(success: false, error: "解析失败 \(avErr(ret))")
        }

        try? FileManager.default.removeItem(at: dest)
        let filename = dest.path
        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        ret = avformat_alloc_output_context2(&outCtx, nil, "mp4", filename)
        guard ret >= 0, let output = outCtx else {
            avformat_close_input(&inCtx)
            return Result(success: false, error: "无法创建 mp4")
        }

        var mapping = [Int: Int]()
        var outIndex = 0
        var audioTaken = false
        var videoTaken = false
        let nb = Int(input.pointee.nb_streams)
        for i in 0..<nb {
            guard let inStream = input.pointee.streams[i],
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
            guard let outStream = avformat_new_stream(output, nil) else { continue }
            avcodec_parameters_copy(outStream.pointee.codecpar, codecpar)
            outStream.pointee.codecpar.pointee.codec_tag = 0
            mapping[i] = outIndex
            outIndex += 1
        }
        guard outIndex > 0 else {
            avformat_free_context(output)
            outCtx = nil
            avformat_close_input(&inCtx)
            return Result(success: false, error: "没有音视频轨道")
        }

        ret = avio_open(&(output.pointee.pb), filename, AVIO_FLAG_WRITE)
        guard ret >= 0 else {
            avformat_free_context(output)
            outCtx = nil
            avformat_close_input(&inCtx)
            return Result(success: false, error: "无法写入文件")
        }
        var muxOpts: OpaquePointer?
        av_dict_set(&muxOpts, "movflags", "frag_keyframe+empty_moov+faststart", 0)
        ret = avformat_write_header(output, &muxOpts)
        av_dict_free(&muxOpts)
        guard ret >= 0 else {
            avio_closep(&(output.pointee.pb))
            avformat_free_context(output)
            outCtx = nil
            avformat_close_input(&inCtx)
            return Result(success: false, error: "写文件头失败 \(avErr(ret))")
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        var firstPts: Int64?
        var lastBytes: Int64 = 0
        let nopts = Int64.min
        while !progress.stopping {
            ret = av_read_frame(input, packet)
            if ret < 0 { break }
            defer { av_packet_unref(packet) }
            guard let pkt = packet else { continue }
            let inIndex = Int(pkt.pointee.stream_index)
            guard let mapped = mapping[inIndex],
                  let inStream = input.pointee.streams[inIndex],
                  let outStream = output.pointee.streams[mapped] else { continue }

            if firstPts == nil, pkt.pointee.pts != nopts {
                firstPts = pkt.pointee.pts
            }
            pkt.pointee.stream_index = Int32(mapped)
            av_packet_rescale_ts(pkt, inStream.pointee.time_base, outStream.pointee.time_base)
            pkt.pointee.pos = -1
            let w = av_interleaved_write_frame(output, pkt)
            if w < 0 { break }

            let tb = inStream.pointee.time_base
            if let first = firstPts, pkt.pointee.dts != nopts {
                let pts = pkt.pointee.dts - first
                let sec = Double(pts) * Double(tb.num) / Double(max(tb.den, 1))
                if sec >= 0 {
                    let size = (try? FileManager.default.attributesOfItem(atPath: filename)[.size] as? Int64) ?? lastBytes
                    lastBytes = size
                    progress.set(seconds: sec, bytes: size)
                }
            }
        }

        av_write_trailer(output)
        avio_closep(&(output.pointee.pb))
        avformat_free_context(output)
        outCtx = nil
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
        av_dict_set(&opts, "referer", "https://chaturbate.com/", 0)
        av_dict_set(
            &opts,
            "headers",
            "Referer: https://chaturbate.com/\r\nUser-Agent: \(ua)\r\nAccept: */*\r\n",
            0
        )
        av_dict_set_int(&opts, "reconnect", 1, 0)
        av_dict_set_int(&opts, "reconnect_streamed", 1, 0)
        av_dict_set_int(&opts, "reconnect_delay_max", 8, 0)
        av_dict_set_int(&opts, "reconnect_on_network_error", 1, 0)
        av_dict_set_int(&opts, "rw_timeout", 20_000_000, 0)
        av_dict_set_int(&opts, "timeout", 20_000_000, 0)
        av_dict_set_int(&opts, "http_persistent", 0, 0)
        av_dict_set_int(&opts, "seekable", 0, 0)
        av_dict_set_int(&opts, "live_start_index", -3, 0)
        av_dict_set(&opts, "allowed_extensions", "ALL", 0)
        av_dict_set(&opts, "protocol_whitelist", "file,http,https,tcp,tls,crypto", 0)
        return opts
    }
}
