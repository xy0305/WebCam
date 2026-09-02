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

/// 用 AVAssetReader（读直播 HLS 音视频轨）+ AVAssetWriter（转封装成 .mp4）录制。
/// 纯系统 AVFoundation 方案：AVPlayer 能播的流（含 LL-HLS 音视频分离），AVAssetReader 一定能读。
/// copy 转封装不重编码，快且能跟上实时；AVAssetWriter.finishWriting 会正确写 moov atom，
/// 即使直播中途停止也能产出可播放文件。
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
    private var outputURL: URL?
    private var workTask: Task<Void, Never>?

    init(username: String, masterURL: URL) {
        self.username = username
        self.masterURL = masterURL
    }

    func start() {
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(username)_\(Self.stamp()).mp4")
        outputURL = url

        isRunning = true
        startedAt = Date()
        startTimer()

        let source = masterURL
        let destination = url
        let name = username
        workTask = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.record(source: source, destination: destination)
            await MainActor.run {
                self?.finish(result: result, name: name, destination: destination)
            }
        }
    }

    /// 录制结果
    private struct RecordResult {
        let success: Bool
        let error: Error?
    }

    /// 核心录制逻辑（后台线程，非隔离）
    nonisolated private static func record(source: URL, destination: URL) async -> RecordResult {
        do {
            try await transcode(source: source, destination: destination)
            return RecordResult(success: true, error: nil)
        } catch {
            return RecordResult(success: false, error: error)
        }
    }

    /// AVAssetReader 读 → AVAssetWriter 写（copy 转封装）
    nonisolated private static func transcode(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)

        // 同步加载轨道（HLS 会阻塞等待 master 加载完成）
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)

        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw StreamSourceError.blocked
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)

        var videoInput: AVAssetWriterInput?
        var videoOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?

        // 视频轨：copy 转封装（不重编码）
        if let videoTrack = videoTracks.first {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                videoInput = input
                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
                if reader.canAdd(output) {
                    reader.add(output)
                    videoOutput = output
                }
            }
        }

        // 音频轨：copy 转封装
        if let audioTrack = audioTracks.first {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
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

        var sessionStarted = false

        // 持续读直播流（HLS 动态分片），直到被取消
        while !Task.isCancelled {
            var gotAny = false

            if let videoOutput, let videoInput, videoInput.isReadyForMoreMediaData {
                while let buffer = videoOutput.copyNextSampleBuffer() {
                    if !sessionStarted {
                        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                        sessionStarted = true
                    }
                    videoInput.append(buffer)
                    gotAny = true
                }
            }

            if let audioOutput, let audioInput, audioInput.isReadyForMoreMediaData {
                while let buffer = audioOutput.copyNextSampleBuffer() {
                    audioInput.append(buffer)
                    gotAny = true
                }
            }

            if !gotAny {
                // 读到当前末尾，稍等新分片
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        // 收尾
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        // 等写完成（正确写 moov atom）
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? StreamSourceError.badResponse
        }
    }

    private func finish(result: RecordResult, name: String, destination: URL) {
        stopTimer()
        isRunning = false
        let msg: String
        if result.success, FileManager.default.fileExists(atPath: destination.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
            bytesText = String(format: "%.1f MB", Double(size) / 1_048_576)
            msg = "\(name) 已保存 \(bytesText)"
        } else {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            msg = "\(name) 录制失败：\(result.error?.localizedDescription ?? "未知")"
        }
        onFinished?(name, msg)
    }

    func stop(userInitiated: Bool) {
        isRunning = false
        stopTimer()
        workTask?.cancel()
        workTask = nil
        // finish 会在 detached task 里收到取消后回调
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
