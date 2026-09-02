import Foundation
import UIKit
import KSPlayer

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

/// 用 KSPlayer 的 MEPlayer（FFmpeg 内核）+ KSOptions.outputURL 录制直播流。
/// FFmpeg 的 `avformat_alloc_output_context2` 会根据文件扩展名（.mp4）推断封装格式，
/// 自动处理 HLS 音视频分离、fMP4 分片转封装，产出可播放的 MP4。
/// 这是 KSPlayer 官方支持的录制方式，无需额外依赖。
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
    private var player: KSMEPlayer?
    private var sizeCheckTimer: Timer?

    init(username: String, masterURL: URL) {
        self.username = username
        self.masterURL = masterURL
        super.init()
    }

    func start() {
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 用 .ts（MPEG-TS 流式格式）而非 .mp4：直播录制中途停止时，
        // MP4 的 moov atom 写不完整会损坏文件；TS 无 moov atom，随时停止都能播放。
        let url = dir.appendingPathComponent("\(username)_\(Self.stamp()).ts")
        outputURL = url

        isRunning = true
        startedAt = Date()
        startTimer()

        // 配置 KSOptions：设置 outputURL 触发 FFmpeg 录制
        let options = KSOptions()
        options.outputURL = url
        KSOptions.isAutoPlay = true
        options.videoAdaptable = false
        // 带上与播放一致的请求头（Referer/UA），确保能拉到源
        options.appendHeader(APIClient.commonHeaders)

        // 用 MEPlayer（FFmpeg 内核）实例拉流录制
        let mePlayer = KSMEPlayer(url: masterURL, options: options)
        player = mePlayer
        mePlayer.prepareToPlay()
        mePlayer.play()

        // 定期检查录制文件大小，更新进度
        sizeCheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFileSize()
            }
        }
    }

    private func updateFileSize() {
        guard let outputURL, FileManager.default.fileExists(atPath: outputURL.path) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        bytesText = String(format: "%.1f MB", Double(size) / 1_048_576)
    }

    func stop(userInitiated: Bool) {
        isRunning = false
        stopTimer()
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = nil

        // shutdown 会触发 FFmpeg 写完成并关闭文件
        player?.shutdown()
        player = nil

        let msg: String
        if let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            updateFileSize()
            msg = "\(username) 已保存 \(bytesText)"
        } else {
            msg = "\(username) 没有录到数据"
        }
        outputURL = nil
        onFinished?(username, msg)
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
