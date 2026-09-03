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
        // 最小合法 WAV：44 字节头 + 0.1s 静音 PCM
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

/// 自己拉 HLS 媒体 playlist 和分片（带 Chaturbate 请求头），拼成 fMP4 / TS。
/// 停录后再用 AVAssetExportSession 把音视频封装成可播 .mp4。
/// AVAssetReader 直接读直播 master 会失败（LL-HLS 音视频分离、无请求头）。
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
    private var startedAt: Date?
    private var workTask: Task<Void, Never>?
    private var videoPartURL: URL?
    private var audioPartURL: URL?

    init(username: String, videoPlaylist: URL, audioPlaylist: URL?) {
        self.username = username
        self.videoPlaylist = videoPlaylist
        self.audioPlaylist = audioPlaylist
    }

    func start() {
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stamp()
        let videoPart = dir.appendingPathComponent("\(username)_\(stamp)_v.part")
        let audioPart = dir.appendingPathComponent("\(username)_\(stamp)_a.part")
        let finalURL = dir.appendingPathComponent("\(username)_\(stamp).mp4")
        videoPartURL = videoPart
        audioPartURL = audioPart

        isRunning = true
        startedAt = Date()
        startTimer()

        let videoPL = videoPlaylist
        let audioPL = audioPlaylist
        let name = username
        workTask = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.harvest(
                videoPlaylist: videoPL,
                audioPlaylist: audioPL,
                videoPart: videoPart,
                audioPart: audioPart,
                finalURL: finalURL
            )
            await MainActor.run {
                self?.finish(result: result, name: name, destination: result.outputURL ?? finalURL)
            }
        }
    }

    private struct HarvestResult {
        let success: Bool
        let outputURL: URL?
        let bytes: Int64
        let error: String?
    }

    nonisolated private static func harvest(
        videoPlaylist: URL,
        audioPlaylist: URL?,
        videoPart: URL,
        audioPart: URL,
        finalURL: URL
    ) async -> HarvestResult {
        do {
            var videoSeen = Set<String>()
            var audioSeen = Set<String>()
            var videoMapDone = false
            var audioMapDone = false
            var wroteVideo: Int64 = 0
            var wroteAudio: Int64 = 0

            while !Task.isCancelled {
                do {
                    wroteVideo += try await pull(
                        playlist: videoPlaylist,
                        dest: videoPart,
                        seen: &videoSeen,
                        mapDone: &videoMapDone
                    )
                    if let audio = audioPlaylist {
                        wroteAudio += try await pull(
                            playlist: audio,
                            dest: audioPart,
                            seen: &audioSeen,
                            mapDone: &audioMapDone
                        )
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // 单次拉 playlist/分片失败不中断整段录制
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            let videoSize = fileSize(videoPart)
            guard videoSize > 1024 else {
                cleanup([videoPart, audioPart])
                return HarvestResult(success: false, outputURL: nil, bytes: 0, error: "没有收到视频分片")
            }

            // 停录后立刻落盘，不把用户拦在 AVAssetExportSession 上（大文件要十几秒）。
            let fallback = fallbackURL(from: videoPart, finalURL: finalURL)
            try? FileManager.default.removeItem(at: fallback)
            try? FileManager.default.moveItem(at: videoPart, to: fallback)
            let savedBytes = fileSize(fallback)
            let hasAudio = wroteAudio > 1024 && fileSize(audioPart) > 1024
            if hasAudio {
                let audio = audioPart
                let muxDest = fallback.deletingPathExtension().appendingPathExtension("mux.part")
                Task.detached(priority: .utility) {
                    if let muxed = await mux(video: fallback, audio: audio, dest: muxDest) {
                        let final = fallback.deletingPathExtension().appendingPathExtension("mp4")
                        if final != fallback {
                            try? FileManager.default.removeItem(at: fallback)
                        }
                        if muxed != final {
                            try? FileManager.default.removeItem(at: final)
                            try? FileManager.default.moveItem(at: muxed, to: final)
                        }
                        await MainActor.run { RecordingManager.shared.noteLibraryChanged() }
                    }
                    cleanup([audio, muxDest])
                }
            } else {
                cleanup([audioPart])
            }
            return HarvestResult(success: true, outputURL: fallback, bytes: savedBytes, error: nil)
        } catch {
            cleanup([videoPart, audioPart])
            return HarvestResult(success: false, outputURL: nil, bytes: 0, error: error.localizedDescription)
        }
    }

    nonisolated private static func pull(
        playlist: URL,
        dest: URL,
        seen: inout Set<String>,
        mapDone: inout Bool
    ) async throws -> Int64 {
        let (data, http) = try await APIClient.hlsData(for: playlist, retry: 0)
        guard (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return 0 }

        let parsed = parseMedia(text, base: playlist)
        var written: Int64 = 0

        if !mapDone, let map = parsed.map {
            let chunk = try await fetchBytes(map)
            try append(chunk, to: dest)
            written += Int64(chunk.count)
            mapDone = true
        }

        for seg in parsed.segments {
            let key = seg.absoluteString
            if seen.contains(key) { continue }
            let chunk = try await fetchBytes(seg)
            try append(chunk, to: dest)
            written += Int64(chunk.count)
            seen.insert(key)
        }
        return written
    }

    nonisolated private static func parseMedia(_ doc: String, base: URL) -> (map: URL?, segments: [URL]) {
        var map: URL?
        var segs: [URL] = []
        var expectURI = false
        let lines = doc.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            if line.hasPrefix("#EXT-X-MAP:") {
                map = extractURI(line, base: base)
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                expectURI = true
                continue
            }
            if expectURI && !line.isEmpty && !line.hasPrefix("#") {
                if let url = resolve(line, base: base) { segs.append(url) }
                expectURI = false
            }
        }
        return (map, segs)
    }

    nonisolated private static func extractURI(_ line: String, base: URL) -> URL? {
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

    nonisolated private static func resolve(_ str: String, base: URL) -> URL? {
        if str.hasPrefix("http://") || str.hasPrefix("https://") { return URL(string: str) }
        return URL(string: str, relativeTo: base)?.absoluteURL
    }

    nonisolated private static func fetchBytes(_ url: URL) async throws -> Data {
        let (data, http) = try await APIClient.hlsData(for: url, retry: 1)
        guard (200..<300).contains(http.statusCode) else {
            throw StreamSourceError.httpStatus(http.statusCode)
        }
        return data
    }

    nonisolated private static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    nonisolated private static func cleanup(_ urls: [URL]) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    nonisolated private static func fallbackURL(from part: URL, finalURL: URL) -> URL {
        if let data = try? Data(contentsOf: part, options: .mappedIfSafe), data.count >= 1, data[0] == 0x47 {
            return finalURL.deletingPathExtension().appendingPathExtension("ts")
        }
        return finalURL
    }

    nonisolated private static func mux(video: URL, audio: URL, dest: URL) async -> URL? {
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)
        let mix = AVMutableComposition()
        do {
            let vTracks = try await vAsset.loadTracks(withMediaType: .video)
            let aTracks = try await aAsset.loadTracks(withMediaType: .audio)
            let vDuration = try await vAsset.load(.duration)
            let aDuration = try await aAsset.load(.duration)
            if let vt = vTracks.first {
                let track = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try track?.insertTimeRange(CMTimeRange(start: .zero, duration: vDuration), of: vt, at: .zero)
            }
            if let at = aTracks.first {
                let track = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                let duration = CMTimeMinimum(vDuration, aDuration)
                try track?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: at, at: .zero)
            }
            guard mix.tracks.isEmpty == false else { return nil }

            try? FileManager.default.removeItem(at: dest)
            guard let session = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough)
                    ?? AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetHighestQuality) else {
                return nil
            }
            session.outputURL = dest
            session.outputFileType = .mp4
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status == .completed, FileManager.default.fileExists(atPath: dest.path), fileSize(dest) > 1024 {
                return dest
            }
            if session.presetName == AVAssetExportPresetPassthrough {
                try? FileManager.default.removeItem(at: dest)
                guard let retry = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetHighestQuality) else {
                    return nil
                }
                retry.outputURL = dest
                retry.outputFileType = .mp4
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    retry.exportAsynchronously { cont.resume() }
                }
                if retry.status == .completed, fileSize(dest) > 1024 { return dest }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func finish(result: HarvestResult, name: String, destination: URL) {
        stopTimer()
        isRunning = false
        let msg: String
        if result.success, let url = result.outputURL, FileManager.default.fileExists(atPath: url.path) {
            let size = result.bytes > 0 ? result.bytes : Self.fileSize(url)
            bytesText = String(format: "%.1f MB", Double(size) / 1_048_576)
            msg = "\(name) 已保存 \(bytesText)"
        } else {
            if FileManager.default.fileExists(atPath: destination.path), Self.fileSize(destination) < 1024 {
                try? FileManager.default.removeItem(at: destination)
            }
            msg = "\(name) 录制失败：\(result.error ?? "未知")"
        }
        onFinished?(name, msg)
    }

    func stop(userInitiated: Bool) {
        isRunning = false
        stopTimer()
        workTask?.cancel()
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        guard let startedAt else { return }
        let s = max(0, Int(Date().timeIntervalSince(startedAt)))
        elapsedText = String(format: "%02d:%02d", s / 60, s % 60)
        if let video = videoPartURL {
            let n = Self.fileSize(video) + (audioPartURL.map { Self.fileSize($0) } ?? 0)
            bytesText = String(format: "%.1f MB", Double(n) / 1_048_576)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
