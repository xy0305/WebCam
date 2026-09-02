import Foundation
import UIKit
import AVFoundation

@MainActor
final class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    @Published private(set) var sessions: [String: RecordingSession] = [:]
    @Published var banner: String?

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var activeUsernames: [String] { Array(sessions.keys).sorted() }
    var isAnyRecording: Bool { !sessions.isEmpty }

    func isRecording(_ username: String) -> Bool {
        sessions[username.lowercased()] != nil
    }

    func session(for username: String) -> RecordingSession? {
        sessions[username.lowercased()]
    }

    func start(username: String, masterURL: URL) {
        let name = username.lowercased()
        guard sessions[name] == nil else { return }
        let session = RecordingSession(username: name, masterURL: masterURL)
        session.onFinished = { [weak self] name, message in
            self?.sessions[name] = nil
            self?.banner = message
            self?.refreshIdle()
        }
        sessions[name] = session
        session.start()
        refreshIdle()
    }

    func stop(_ username: String) {
        sessions[username.lowercased()]?.stop(userInitiated: true)
    }

    func toggle(username: String, masterURL: URL) {
        if isRecording(username) {
            stop(username)
        } else {
            start(username: username, masterURL: masterURL)
        }
    }

    private func refreshIdle() {
        UIApplication.shared.isIdleTimerDisabled = isAnyRecording
        if isAnyRecording {
            extendBackground()
        } else {
            endBackground()
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

/// 自己拉 HLS 媒体 playlist 和分片（带 Chaturbate 请求头），拼成 fMP4 / TS。
/// 停录后再用 AVAssetExportSession 把音视频封装成可播 .mp4。
/// AVAssetReader 直接读直播 master 会失败（LL-HLS 音视频分离、无请求头）。
@MainActor
final class RecordingSession: ObservableObject, Identifiable {
    var id: String { username }
    let username: String
    let masterURL: URL

    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var isRunning = false

    var onFinished: ((String, String) -> Void)?

    private var timer: Timer?
    private var startedAt: Date?
    private var workTask: Task<Void, Never>?
    private var videoPartURL: URL?
    private var audioPartURL: URL?

    init(username: String, masterURL: URL) {
        self.username = username
        self.masterURL = masterURL
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

        let master = masterURL
        let name = username
        workTask = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.harvest(
                master: master,
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
        master: URL,
        videoPart: URL,
        audioPart: URL,
        finalURL: URL
    ) async -> HarvestResult {
        do {
            let lists = try await StreamSource.playlists(from: master)
            var videoSeen = Set<String>()
            var audioSeen = Set<String>()
            var videoMapDone = false
            var audioMapDone = false
            var wroteVideo: Int64 = 0
            var wroteAudio: Int64 = 0

            while !Task.isCancelled {
                do {
                    wroteVideo += try await pull(
                        playlist: lists.video,
                        dest: videoPart,
                        seen: &videoSeen,
                        mapDone: &videoMapDone
                    )
                    if let audio = lists.audio {
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

            if wroteAudio > 1024, fileSize(audioPart) > 1024 {
                if let muxed = await mux(video: videoPart, audio: audioPart, dest: finalURL) {
                    cleanup([videoPart, audioPart])
                    return HarvestResult(success: true, outputURL: muxed, bytes: fileSize(muxed), error: nil)
                }
            }

            let fallback = fallbackURL(from: videoPart, finalURL: finalURL)
            try? FileManager.default.moveItem(at: videoPart, to: fallback)
            cleanup([audioPart, videoPart])
            return HarvestResult(success: true, outputURL: fallback, bytes: fileSize(fallback), error: nil)
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
        var req = URLRequest(url: playlist)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await APIClient.data(for: req, retry: 0)
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
        var req = URLRequest(url: url)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await APIClient.data(for: req, retry: 1)
        guard (200..<300).contains(http.statusCode) else { throw StreamSourceError.badResponse }
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
        workTask?.cancel()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                let s = Int(Date().timeIntervalSince(startedAt))
                self.elapsedText = String(format: "%02d:%02d", s / 60, s % 60)
                if let video = self.videoPartURL {
                    let n = Self.fileSize(video) + (self.audioPartURL.map { Self.fileSize($0) } ?? 0)
                    self.bytesText = String(format: "%.1f MB", Double(n) / 1_048_576)
                }
            }
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
