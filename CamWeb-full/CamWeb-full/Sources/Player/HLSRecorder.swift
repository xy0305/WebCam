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
        banner = "开始录制 \(name)"
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

/// 用 AVAssetReader 读直播 HLS 的音视频轨，AVAssetWriter 转封装成可播放的 .mp4。
/// 纯系统 API，无第三方依赖，GitHub Actions 可直接编译。
@MainActor
final class RecordingSession: NSObject, ObservableObject, Identifiable {
    var id: String { username }
    let username: String
    let masterURL: URL

    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var isRunning = false

    var onFinished: ((String, String) -> Void)?

    private var timer: Timer?
    private var startedAt: Date?
    private var outputURL: URL?
    private var workTask: Task<Void, Never>?

    init(username: String, masterURL: URL) {
        self.username = username
        self.masterURL = masterURL
        super.init()
    }

    func start() {
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(username)_\(Self.stamp()).mp4")
        outputURL = url

        isRunning = true
        startedAt = Date()
        startTimer()

        let src = masterURL
        let dst = url
        workTask = Task.detached(priority: .utility) {
            await self.runRecord(source: src, destination: dst)
        }
    }

    private func runRecord(source: URL, destination: URL) async {
        do {
            try await transcode(source: source, destination: destination)
            await MainActor.run { self.finish(success: true) }
        } catch {
            await MainActor.run { self.finish(success: false, error: error) }
        }
    }

    /// 核心：AVAssetReader 读 → AVAssetWriter 写
    private func transcode(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)

        // 等待轨道加载
        try await loadTracks(asset)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)

        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var videoOutput: AVAssetReaderTrackOutput?
        var audioOutput: AVAssetReaderTrackOutput?

        // 视频轨
        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoTrack.naturalSize.width,
                AVVideoHeightKey: videoTrack.naturalSize.height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            input.transform = videoTrack.preferredTransform
            if writer.canAdd(input) {
                writer.add(input)
                videoInput = input
                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ])
                if reader.canAdd(output) {
                    reader.add(output)
                    videoOutput = output
                }
            }
        }

        // 音频轨
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM
                ])
                if reader.canAdd(output) {
                    reader.add(output)
                    audioOutput = output
                }
            }
        }

        guard videoOutput != nil || audioOutput != nil else {
            throw StreamSourceError.blocked
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // 并发写
        try await withThrowingTaskGroup(of: Void.self) { group in
            if let videoInput, let videoOutput {
                group.addTask { try await self.pipeVideo(output: videoOutput, input: videoInput) }
            }
            if let audioInput, let audioOutput {
                group.addTask { try await self.pipeAudio(output: audioOutput, input: audioInput) }
            }
            try await group.waitForAll()
        }

        // 等写完成
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? StreamSourceError.badResponse
        }
    }

    private func pipeVideo(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) async throws {
        while input.isReadyForMoreMediaData {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            input.append(buffer)
        }
        input.markAsFinished()
    }

    private func pipeAudio(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) async throws {
        while input.isReadyForMoreMediaData {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            input.append(buffer)
        }
        input.markAsFinished()
    }

    private func loadTracks(_ asset: AVURLAsset) async throws {
        let tracks = try await asset.load(.tracks)
        guard !tracks.isEmpty else {
            throw StreamSourceError.badResponse
        }
    }

    private func finish(success: Bool, error: Error? = nil) {
        stopTimer()
        isRunning = false
        let msg: String
        if success, let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
            bytesText = String(format: "%.1f MB", Double(size) / 1_048_576)
            msg = "\(username) 已保存 \(bytesText)"
        } else {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            msg = "\(username) 录制失败：\(error?.localizedDescription ?? "未知")"
        }
        onFinished?(username, msg)
    }

    func stop(userInitiated: Bool) {
        isRunning = false
        workTask?.cancel()
        workTask = nil
        stopTimer()
        finish(success: false, error: nil)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                let s = Int(Date().timeIntervalSince(startedAt))
                self.elapsedText = String(format: "%02d:%02d", s / 60, s % 60)
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
