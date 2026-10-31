import Foundation

#if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil) && canImport(Libswresample)
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// Audio-only FFmpeg demux/decode of the live play URL.
/// Mirrors AVDB LiveAudioReader ideas: interrupt on hold/stop, lowest-bitrate HLS audio variant,
/// never tap the player render path so captions do not freeze KSPlayer.
final class LiveCaptionAudioReader: @unchecked Sendable {
    struct Source: Equatable, Sendable {
        var url: URL
        var headers: [String: String]

        init(url: URL, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }
    }

    /// (PCM 16 kHz mono Float32, media start time seconds, generation)
    var onPCM: (@Sendable ([Float], Double, Int) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onInfo: (@Sendable (String) -> Void)?
    /// Return false to pause reading (reader is far enough ahead / player needs bandwidth).
    var shouldRun: (@Sendable () -> Bool)?

    private let cond = NSCondition()
    private var thread: Thread?
    private var source: Source?
    private var stopped = true
    private var token = 0
    fileprivate var interrupted = false
    fileprivate var abortIO = false
    private var hold = false
    private var generation = 0

    init() {}

    var isRunning: Bool {
        cond.lock(); defer { cond.unlock() }
        return !stopped && thread != nil
    }

    func start(_ source: Source, generation: Int = 0) {
        stop()
        cond.lock()
        self.source = source
        self.generation = generation
        stopped = false
        interrupted = false
        abortIO = false
        hold = false
        token += 1
        let tok = token
        let t = Thread { [weak self] in self?.run(tok) }
        t.name = "camweb.livecaption.audio"
        t.qualityOfService = .utility
        thread = t
        cond.unlock()
        t.start()
    }

    func holdForBandwidth(_ on: Bool) {
        cond.lock()
        hold = on
        if on { abortIO = true }
        else { abortIO = false }
        cond.broadcast()
        cond.unlock()
    }

    func poke() {
        cond.lock(); cond.broadcast(); cond.unlock()
    }

    func stop() {
        cond.lock()
        stopped = true
        interrupted = true
        abortIO = true
        hold = false
        thread = nil
        cond.broadcast()
        cond.unlock()
    }

    private func dead(_ tok: Int) -> Bool {
        cond.lock(); defer { cond.unlock() }
        return stopped || tok != token
    }

    private func run(_ tok: Int) {
        var attempts = 0
        while !dead(tok) {
            cond.lock()
            let source = self.source
            let generation = self.generation
            cond.unlock()
            guard let source else { return }
            switch session(source, tok: tok, generation: generation) {
            case .stopped:
                return
            case .ended:
                // Live streams rarely EOF; wait for stop / restart.
                waitInterruptible(tok, timeout: 2)
                attempts = 0
            case .failed(let msg):
                attempts += 1
                if attempts == 3 { onError?(msg) }
                waitInterruptible(tok, timeout: min(15, pow(2, Double(attempts - 1))))
            }
        }
    }

    private func waitInterruptible(_ tok: Int, timeout: Double) {
        cond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !stopped, tok == token {
            if !cond.wait(until: deadline) { break }
        }
        cond.unlock()
    }

    private enum Outcome { case stopped, ended, failed(String) }

    private static let errEOF: Int32 = -541_478_725
    private static let chunkSamples = LiveCaptionAudio.chunkSamples / 4 // flush ~0.6 s pieces upstream

    private func session(_ source: Source, tok: Int, generation: Int) -> Outcome {
        var fmt: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard fmt != nil else { return .failed("avformat_alloc_context") }

        var cb = AVIOInterruptCB()
        cb.opaque = Unmanaged.passUnretained(self).toOpaque()
        cb.callback = { ctx -> Int32 in
            guard let ctx else { return 0 }
            let reader = Unmanaged<LiveCaptionAudioReader>.fromOpaque(ctx).takeUnretainedValue()
            return (reader.interrupted || reader.abortIO) ? 1 : 0
        }
        fmt?.pointee.interrupt_callback = cb

        var opts: OpaquePointer?
        var headers = source.headers
        if let ua = headers.removeValue(forKey: "User-Agent") ?? headers.removeValue(forKey: "user-agent") {
            av_dict_set(&opts, "user_agent", ua, 0)
        }
        // Pass Referer only once (option), not again inside the raw `headers` blob.
        if let ref = headers.removeValue(forKey: "Referer") ?? headers.removeValue(forKey: "referer") {
            av_dict_set(&opts, "referer", ref, 0)
        }
        if !headers.isEmpty {
            av_dict_set(&opts, "headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined(), 0)
        }
        av_dict_set(&opts, "reconnect", "1", 0)
        av_dict_set(&opts, "reconnect_streamed", "1", 0)
        av_dict_set(&opts, "reconnect_delay_max", "4", 0)
        av_dict_set(&opts, "rw_timeout", "15000000", 0)
        av_dict_set(&opts, "extension_picky", "0", 0)
        av_dict_set(&opts, "allowed_extensions", "ALL", 0)
        // Live HLS (Chaturbate LL-HLS fMP4 audio chunklist): start near the live edge like the player,
        // retry a missing live segment instead of failing the whole session, never seek on live.
        av_dict_set(&opts, "live_start_index", "-3", 0)
        av_dict_set(&opts, "seg_max_retry", "3", 0)
        av_dict_set(&opts, "http_persistent", "1", 0)
        av_dict_set(&opts, "probesize", "2000000", 0)
        av_dict_set(&opts, "analyzeduration", "2000000", 0)

        let urlString = source.url.isFileURL ? source.url.path : source.url.absoluteString
        let openErr = avformat_open_input(&fmt, urlString, nil, &opts)
        av_dict_free(&opts)
        guard openErr == 0, let ctx = fmt else {
            return dead(tok) ? .stopped : .failed("open \(openErr)")
        }
        defer {
            fmt?.pointee.interrupt_callback.opaque = nil
            fmt?.pointee.interrupt_callback.callback = nil
            avformat_close_input(&fmt)
        }
        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            return dead(tok) ? .stopped : .failed("stream info")
        }

        var decoder: UnsafePointer<AVCodec>?
        let related = Self.lowestVariantStream(ctx)
        let index = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, related, &decoder, 0)
        guard index >= 0, let decoder else { return .failed("no audio stream") }
        for i in 0 ..< Int(ctx.pointee.nb_streams) where i != Int(index) {
            ctx.pointee.streams[i]?.pointee.discard = AVDISCARD_ALL
        }
        guard let stream = ctx.pointee.streams[Int(index)] else { return .failed("stream") }
        var codec: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codec) }
        guard let codec,
              avcodec_parameters_to_context(codec, stream.pointee.codecpar) >= 0,
              avcodec_open2(codec, decoder, nil) >= 0 else {
            return .failed("decoder")
        }

        let tb = stream.pointee.time_base
        let tbSeconds = Double(tb.num) / Double(max(1, tb.den))
        let startOffset = ctx.pointee.start_time == Int64.min ? 0 : Double(ctx.pointee.start_time) / 1_000_000

        var swr: OpaquePointer?
        defer { swr_free(&swr) }
        var swrKey: (Int32, Int32, Int32) = (0, -1, 0)

        let pkt = av_packet_alloc()
        let frame = av_frame_alloc()
        defer {
            var p = pkt; av_packet_free(&p)
            var f = frame; av_frame_free(&f)
        }
        guard let pkt, let frame else { return .failed("alloc") }

        var pending: [Float] = []
        var pendingStart = 0.0
        var cursor: Double?

        func flush() {
            guard !pending.isEmpty else { return }
            onPCM?(pending, pendingStart, generation)
            pendingStart += Double(pending.count) / LiveCaptionAudio.sampleRate
            pending.removeAll(keepingCapacity: true)
        }

        while true {
            if dead(tok) { return .stopped }

            cond.lock()
            while !stopped, tok == token, hold || !(shouldRun?() ?? true) {
                _ = cond.wait(until: Date().addingTimeInterval(0.1))
            }
            let holding = hold
            cond.unlock()
            if dead(tok) { return .stopped }
            if holding { continue }

            let r = av_read_frame(ctx, pkt)
            if r < 0 {
                if dead(tok) { return .stopped }
                cond.lock(); let holdingNow = hold; cond.unlock()
                if holdingNow { continue }
                if r == Self.errEOF || ctx.pointee.pb?.pointee.eof_reached == 1 {
                    flush()
                    return .ended
                }
                return .failed("read \(r)")
            }
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == index else { continue }
            guard avcodec_send_packet(codec, pkt) >= 0 else { continue }

            while avcodec_receive_frame(codec, frame) >= 0 {
                defer { av_frame_unref(frame) }
                let n = Int(frame.pointee.nb_samples)
                guard n > 0 else { continue }
                let channels = frame.pointee.ch_layout.nb_channels
                let key: (Int32, Int32, Int32) = (frame.pointee.sample_rate, frame.pointee.format, channels)
                if swr == nil || key != swrKey {
                    swr_free(&swr)
                    var outLayout = AVChannelLayout()
                    av_channel_layout_default(&outLayout, 1)
                    var inLayout = frame.pointee.ch_layout
                    swr_alloc_set_opts2(
                        &swr,
                        &outLayout,
                        AV_SAMPLE_FMT_FLT,
                        Int32(LiveCaptionAudio.sampleRate),
                        &inLayout,
                        AVSampleFormat(rawValue: frame.pointee.format),
                        frame.pointee.sample_rate,
                        0,
                        nil
                    )
                    guard swr != nil, swr_init(swr) >= 0 else { return .failed("swr") }
                    swrKey = key
                }

                let pts = frame.pointee.best_effort_timestamp
                let frameTime = pts == Int64.min ? (cursor ?? 0) : Double(pts) * tbSeconds - startOffset
                if cursor == nil || abs(frameTime - (cursor ?? 0)) > 0.5 {
                    flush()
                    cursor = frameTime
                    pendingStart = frameTime
                }

                let maxOut = Int(swr_get_out_samples(swr, Int32(n))) + 32
                var out = [Float](repeating: 0, count: maxOut)
                let planes = av_sample_fmt_is_planar(AVSampleFormat(rawValue: frame.pointee.format)) != 0 ? Int(channels) : 1
                var inPtrs: [UnsafePointer<UInt8>?] = (0 ..< planes).map { UnsafePointer(frame.pointee.extended_data[$0]) }
                let got: Int32 = out.withUnsafeMutableBytes { raw in
                    var outPtrs: [UnsafeMutablePointer<UInt8>?] = [raw.baseAddress?.assumingMemoryBound(to: UInt8.self)]
                    return swr_convert(swr, &outPtrs, Int32(maxOut), &inPtrs, Int32(n))
                }
                guard got > 0 else { continue }
                let samples = Array(out.prefix(Int(got)))
                let chunkStart = cursor ?? frameTime
                cursor = chunkStart + Double(got) / LiveCaptionAudio.sampleRate
                if pending.isEmpty {
                    pendingStart = (cursor ?? 0) - Double(samples.count) / LiveCaptionAudio.sampleRate
                }
                pending += samples
                if pending.count >= Self.chunkSamples { flush() }
            }
        }
    }

    private static func lowestVariantStream(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Int32 {
        let n = Int(ctx.pointee.nb_programs)
        guard n > 1, let programs = ctx.pointee.programs else { return -1 }
        var best: (rate: Int, stream: Int32)?
        for i in 0 ..< n {
            guard let prog = programs[i], prog.pointee.nb_stream_indexes > 0, let idx = prog.pointee.stream_index else { continue }
            let rate = av_dict_get(prog.pointee.metadata, "variant_bitrate", nil, 0)
                .flatMap { Int(String(cString: $0.pointee.value)) } ?? Int.max
            var audio: Int32?
            for k in 0 ..< Int(prog.pointee.nb_stream_indexes) {
                let si = Int(idx[k])
                if let st = ctx.pointee.streams[si], st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                    audio = Int32(si)
                    break
                }
            }
            guard let audio else { continue }
            if best == nil || rate < best!.rate { best = (rate, audio) }
        }
        return best?.stream ?? -1
    }
}

#else

/// Stub when FFmpegKit / Libav is not linked (e.g. USE_VLC=1 builds).
final class LiveCaptionAudioReader: @unchecked Sendable {
    struct Source: Equatable, Sendable {
        var url: URL
        var headers: [String: String]
        init(url: URL, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }
    }

    var onPCM: (@Sendable ([Float], Double, Int) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onInfo: (@Sendable (String) -> Void)?
    var shouldRun: (@Sendable () -> Bool)?
    var isRunning: Bool { false }

    init() {}
    func start(_ source: Source, generation: Int = 0) {
        onError?("当前播放内核未链接 FFmpeg，无法开启实时翻译")
    }
    func holdForBandwidth(_ on: Bool) {}
    func poke() {}
    func stop() {}
}

#endif
