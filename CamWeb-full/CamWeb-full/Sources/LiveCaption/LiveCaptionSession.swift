import Foundation
import Observation

/// Owns the audio reader + EN ASR + Apple MT pipeline for one playback URL.
@MainActor
@Observable
final class LiveCaptionSession {
    /// Mints a brand-new play URL for the current room/quality (re-runs the plugin).
    /// Required for single-use-token platforms (Chaturbate) and used to recover from expired sessions.
    typealias SourceRefresher = @Sendable () async -> LiveCaptionSource?

    private(set) var phase: LiveCaptionPhase = .idle
    private(set) var latest: LiveCaptionLine?
    private(set) var statusMessage: String = ""
    private(set) var lastError: String?

    /// Soft lead for the secondary demux so it does not race too far ahead of live.
    var maxLeadSeconds: TimeInterval = 4

    @ObservationIgnored private let reader = LiveCaptionAudioReader()
    @ObservationIgnored private var recognizer: (any LiveCaptionRecognizing)?
    @ObservationIgnored private var translator: (any LiveCaptionTranslating)?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var pcmContinuation: AsyncStream<(samples: [Float], time: Double, generation: Int)>.Continuation?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var buffered: [Float] = []
    @ObservationIgnored private var bufferStart: Double = 0
    @ObservationIgnored private var refresher: SourceRefresher?
    @ObservationIgnored private var activeSource: LiveCaptionSource?
    @ObservationIgnored private var recoverTask: Task<Void, Never>?
    @ObservationIgnored private var recoveries: [Date] = []

    /// Cross-isolation pacing state read by the FFmpeg reader thread.
    @ObservationIgnored private let pace = PaceClock()

    /// iOS 18–25 Translation bridge exposed for the SwiftUI `.translationTask` host.
    private(set) var translationBridge: AnyObject?

    init() {}

    var isActive: Bool {
        phase == .running || phase == .starting
    }

    func start(source: LiveCaptionSource, refresh: SourceRefresher? = nil) async {
        if isActive {
            await stop(clearText: false)
        }
        refresher = refresh
        activeSource = source
        recoveries.removeAll()
        phase = .starting
        lastError = nil
        statusMessage = "正在启动实时翻译…"
        generation &+= 1
        let gen = generation
        buffered.removeAll(keepingCapacity: true)
        latest = nil
        pace.reset(maxLead: maxLeadSeconds)

        do {
            #if os(iOS) || os(macOS)
            let recognizer = try await LiveCaptionEnglishRecognizer.make()
            try await recognizer.prepare()
            self.recognizer = recognizer

            let translator: any LiveCaptionTranslating
            if #available(iOS 26.0, macOS 26.0, *) {
                #if canImport(Translation)
                let direct = LiveCaptionDirectTranslator()
                try await direct.prepare()
                translator = direct
                translationBridge = nil
                #else
                throw LiveCaptionEngineError.translationUnsupported
                #endif
            } else if #available(iOS 18.0, macOS 15.0, *) {
                #if canImport(Translation)
                let bridge = LiveCaptionTranslationBridge()
                try await bridge.prepare()
                bridge.activate()
                translator = bridge
                translationBridge = bridge
                #else
                throw LiveCaptionEngineError.translationUnsupported
                #endif
            } else {
                throw LiveCaptionEngineError.unavailable("实时翻译需要 iOS 18 或更新系统")
            }
            self.translator = translator
            #else
            throw LiveCaptionEngineError.unavailable("当前平台不支持实时翻译")
            #endif

            let (stream, cont) = AsyncStream.makeStream(
                of: (samples: [Float], time: Double, generation: Int).self
            )
            pcmContinuation = cont
            let pace = self.pace
            reader.onPCM = { samples, time, g in
                pace.noteMedia(time + Double(samples.count) / LiveCaptionAudio.sampleRate)
                cont.yield((samples, time, g))
            }
            reader.onError = { [weak self] message in
                Task { @MainActor in
                    self?.readerFailed(message, generation: gen)
                }
            }
            reader.shouldRun = {
                pace.shouldRun()
            }

            statusMessage = "正在连接直播音频…"
            let readerSource = try await Self.resolveReaderSource(source, refresh: refresh)
            guard gen == generation else { return }
            reader.start(readerSource, generation: gen)
            processTask = Task { [weak self] in
                await self?.consume(stream, generation: gen)
            }
            phase = .running
            statusMessage = "实时翻译运行中"
        } catch {
            phase = .failed
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
            await tearDownWorkers()
        }
    }

    /// UI-first stop: caller should clear overlay text immediately, then await this.
    func stop(clearText: Bool = true) async {
        phase = .stopping
        statusMessage = ""
        if clearText { latest = nil }
        await tearDownWorkers()
        phase = .idle
    }

    func holdForBandwidth(_ on: Bool) {
        reader.holdForBandwidth(on)
        pace.setHold(on)
    }

    func retarget(source: LiveCaptionSource, refresh: SourceRefresher? = nil) async {
        guard isActive || phase == .failed else { return }
        await start(source: source, refresh: refresh ?? refresher)
    }

    // MARK: - Audio source resolution (live HLS)

    /// Reader gave up after its own retries (e.g. Chaturbate session expired → 403).
    /// Re-mint the play URL at the live edge instead of hammering the dead one. Bounded so a room
    /// that went private/offline does not loop forever.
    private func readerFailed(_ message: String, generation gen: Int) {
        guard gen == generation, phase == .running else { return }
        let now = Date()
        recoveries = recoveries.filter { now.timeIntervalSince($0) < 120 }
        guard let source = activeSource, recoveries.count < 4,
              source.requiresFreshPlaylist || refresher != nil else {
            lastError = message
            statusMessage = "直播音频读取失败：\(message)"
            return
        }
        recoveries.append(now)
        statusMessage = "直播音频中断，正在重连…"
        recoverTask?.cancel()
        let refresh = refresher
        recoverTask = Task { [weak self] in
            do {
                let fresh = try await Self.resolveReaderSource(source, refresh: refresh, forceRefresh: true)
                guard let self, !Task.isCancelled, gen == self.generation, self.phase == .running else { return }
                self.pace.reset(maxLead: self.maxLeadSeconds)
                self.reader.start(fresh, generation: gen)
                self.statusMessage = "实时翻译运行中"
            } catch {
                guard let self, gen == self.generation else { return }
                self.lastError = error.localizedDescription
                self.statusMessage = error.localizedDescription
            }
        }
    }

    nonisolated static func readerHeaders(_ source: LiveCaptionSource) -> [String: String] {
        var headers = source.headers
        if headers["User-Agent"] == nil && headers["user-agent"] == nil {
            headers["User-Agent"] = source.userAgent
        }
        return headers
    }

    /// Turn the player's play URL into what the audio reader should open:
    /// - single-use-token platforms (Chaturbate) always get a freshly minted URL, never the player's;
    /// - HLS masters are resolved here to the audio-only rendition / lowest variant so FFmpeg does not
    ///   probe every video variant (measured on Chaturbate: ~5 s vs ~20–27 s to first audio).
    nonisolated static func resolveReaderSource(
        _ source: LiveCaptionSource,
        refresh: SourceRefresher?,
        forceRefresh: Bool = false
    ) async throws -> LiveCaptionAudioReader.Source {
        var candidate = source
        if source.requiresFreshPlaylist || forceRefresh {
            if let refresh, let fresh = await refresh() {
                candidate = fresh
            } else if source.requiresFreshPlaylist {
                throw LiveCaptionEngineError.unavailable("无法获取字幕音频地址（直播可能已结束或转私密）")
            }
        }

        for attempt in 0 ..< 2 {
            let headers = readerHeaders(candidate)
            guard LiveCaptionHLS.looksLikeHLS(candidate.url) else {
                return .init(url: candidate.url, headers: headers)
            }
            switch await fetchPlaylist(candidate.url, headers: headers) {
            case .master(let audioURL):
                return .init(url: audioURL, headers: headers)
            case .media:
                return .init(url: candidate.url, headers: headers)
            case .invalid(let reason):
                if attempt == 0, let refresh, let fresh = await refresh() {
                    candidate = fresh
                    continue
                }
                if candidate.requiresFreshPlaylist {
                    throw LiveCaptionEngineError.unavailable("字幕音频地址不可用：\(reason)")
                }
                // Unknown platform / transient network: let FFmpeg try the URL itself (old behavior).
                return .init(url: candidate.url, headers: headers)
            }
        }
        return .init(url: candidate.url, headers: readerHeaders(candidate))
    }

    nonisolated static func fetchPlaylist(_ url: URL, headers: [String: String]) async -> LiveCaptionHLS.Playlist {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200 ..< 300).contains(status) else { return .invalid("HTTP \(status)") }
            let base = response.url ?? url
            return LiveCaptionHLS.classify(String(decoding: data, as: UTF8.self), baseURL: base)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private func tearDownWorkers() async {
        recoverTask?.cancel()
        recoverTask = nil
        processTask?.cancel()
        processTask = nil
        pcmContinuation?.finish()
        pcmContinuation = nil
        reader.stop()
        translator?.shutdown()
        translator = nil
        recognizer = nil
        translationBridge = nil
        buffered.removeAll(keepingCapacity: false)
    }

    private func consume(
        _ stream: AsyncStream<(samples: [Float], time: Double, generation: Int)>,
        generation: Int
    ) async {
        for await packet in stream {
            if Task.isCancelled { break }
            guard packet.generation == generation else { continue }
            if buffered.isEmpty { bufferStart = packet.time }
            buffered.append(contentsOf: packet.samples)
            while buffered.count >= LiveCaptionAudio.chunkSamples {
                let chunk = Array(buffered.prefix(LiveCaptionAudio.chunkSamples))
                buffered.removeFirst(LiveCaptionAudio.chunkSamples)
                let start = bufferStart
                bufferStart += Double(LiveCaptionAudio.chunkSamples) / LiveCaptionAudio.sampleRate
                await processChunk(chunk, mediaTime: start, generation: generation)
            }
        }
    }

    private func processChunk(_ samples: [Float], mediaTime: Double, generation: Int) async {
        guard generation == self.generation, let recognizer, let translator else { return }
        if LiveCaptionAudio.isSilent(samples) { return }
        do {
            let english = try await recognizer.transcribe(samples: samples)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, generation == self.generation else { return }
            let chinese = try await translator.translate(english)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chinese.isEmpty, generation == self.generation else { return }
            latest = LiveCaptionLine(english: english, chinese: chinese, mediaTime: mediaTime)
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// Lock-protected pacing so the FFmpeg reader thread never hops to the MainActor.
private final class PaceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallAnchor = Date()
    private var mediaAnchor: Double = 0
    private var lastMedia: Double = 0
    private var maxLead: TimeInterval = 4
    private var hold = false
    private var started = false

    func reset(maxLead: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.maxLead = maxLead
        wallAnchor = Date()
        mediaAnchor = 0
        lastMedia = 0
        hold = false
        started = false
    }

    func setHold(_ on: Bool) {
        lock.lock(); hold = on; lock.unlock()
    }

    func noteMedia(_ t: Double) {
        lock.lock(); defer { lock.unlock() }
        if !started {
            started = true
            mediaAnchor = t
            wallAnchor = Date()
        }
        lastMedia = t
    }

    func shouldRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if hold { return false }
        guard started else { return true }
        let wall = Date().timeIntervalSince(wallAnchor)
        let media = max(0, lastMedia - mediaAnchor)
        return (media - wall) < maxLead
    }
}
