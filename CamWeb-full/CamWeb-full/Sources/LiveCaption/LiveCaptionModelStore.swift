import Foundation
import WhisperKit

/// Downloads / tracks on-device caption models (Whisper CoreML + Qwen GGUF) with progress for the UI.
@MainActor
final class LiveCaptionModelStore: ObservableObject {
    static let shared = LiveCaptionModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        /// Download done; first load / CoreML specialization (Whisper only).
        case preparing
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .notDownloaded: return "未下载"
            case .downloading(let p): return "下载中 \(Int(p * 100))%"
            case .preparing: return "首次优化模型中（1–3 分钟）…"
            case .ready: return "已就绪"
            case .failed(let m): return "失败：\(m)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .downloading, .preparing: return true
            default: return false
            }
        }
    }

    static let qwenFileName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
    static let qwenURL = URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
    /// ~1.12 GB (1,117,320,736 bytes).
    static let qwenExpectedBytes: Int64 = 1_117_320_736

    @Published private(set) var whisperStates: [LiveCaptionWhisperModel: State] = [:]
    @Published private(set) var qwenState: State = .notDownloaded

    /// Fires when a Whisper model becomes ready (so an active caption session can switch over).
    var onWhisperReady: ((LiveCaptionWhisperModel) -> Void)?

    private var whisperTasks: [LiveCaptionWhisperModel: Task<Void, Never>] = [:]
    private var qwenTask: Task<Void, Never>?

    private init() {
        for m in LiveCaptionWhisperModel.allCases {
            whisperStates[m] = Self.whisperFolder(m) != nil && UserDefaults.standard.bool(forKey: Self.preparedKey(m)) ? .ready : .notDownloaded
        }
        qwenState = Self.qwenPathIfPresent() != nil ? .ready : .notDownloaded
    }

    // MARK: Paths

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiveCaptionModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }

    nonisolated static var whisperBase: URL { root.appendingPathComponent("whisper", isDirectory: true) }

    nonisolated private static func preparedKey(_ m: LiveCaptionWhisperModel) -> String { "camweb.whisperPrepared.\(m.rawValue)" }

    /// Hub layout: <base>/models/argmaxinc/whisperkit-coreml/<variant>
    nonisolated static func whisperFolder(_ m: LiveCaptionWhisperModel) -> URL? {
        let dir = whisperBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(m.rawValue, isDirectory: true)
        let marker = dir.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: marker.path) ? dir : nil
    }

    nonisolated static func readyWhisperFolder(_ m: LiveCaptionWhisperModel) -> URL? {
        guard UserDefaults.standard.bool(forKey: preparedKey(m)) else { return nil }
        return whisperFolder(m)
    }

    nonisolated static func qwenPathIfPresent() -> URL? {
        let url = root.appendingPathComponent(qwenFileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value >= qwenExpectedBytes - 1024 else { return nil }
        return url
    }

    func whisperState(_ m: LiveCaptionWhisperModel) -> State { whisperStates[m] ?? .notDownloaded }

    // MARK: Whisper

    func downloadWhisper(_ m: LiveCaptionWhisperModel) {
        guard whisperTasks[m] == nil, whisperState(m) != .ready else { return }
        whisperStates[m] = .downloading(0)
        whisperTasks[m] = Task { [weak self] in
            do {
                let folder = try await WhisperKit.download(
                    variant: m.rawValue,
                    downloadBase: Self.whisperBase,
                    progressCallback: { progress in
                        let p = progress.fractionCompleted
                        Task { @MainActor in
                            guard let self, case .downloading = self.whisperState(m) else { return }
                            self.whisperStates[m] = .downloading(p)
                        }
                    }
                )
                await MainActor.run { self?.whisperStates[m] = .preparing }
                // First load fetches the tokenizer and lets CoreML specialize the model for this device.
                try await LiveCaptionWhisperEngine.shared.load(folder: folder)
                UserDefaults.standard.set(true, forKey: Self.preparedKey(m))
                await MainActor.run {
                    self?.whisperStates[m] = .ready
                    self?.whisperTasks[m] = nil
                    self?.onWhisperReady?(m)
                }
            } catch {
                await MainActor.run {
                    self?.whisperStates[m] = .failed(error.localizedDescription)
                    self?.whisperTasks[m] = nil
                }
            }
        }
    }

    func deleteWhisper(_ m: LiveCaptionWhisperModel) {
        whisperTasks[m]?.cancel()
        whisperTasks[m] = nil
        UserDefaults.standard.set(false, forKey: Self.preparedKey(m))
        if let dir = Self.whisperFolder(m) { try? FileManager.default.removeItem(at: dir) }
        Task { await LiveCaptionWhisperEngine.shared.unload() }
        whisperStates[m] = .notDownloaded
    }

    // MARK: Qwen

    func downloadQwen() {
        guard qwenTask == nil, qwenState != .ready else { return }
        qwenState = .downloading(0)
        qwenTask = Task { [weak self] in
            do {
                let dest = Self.root.appendingPathComponent(Self.qwenFileName)
                try await FileDownloader.download(Self.qwenURL, to: dest) { p in
                    Task { @MainActor in
                        guard let self, case .downloading = self.qwenState else { return }
                        self.qwenState = .downloading(p)
                    }
                }
                guard Self.qwenPathIfPresent() != nil else { throw URLError(.cannotParseResponse) }
                await MainActor.run {
                    self?.qwenState = .ready
                    self?.qwenTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.qwenState = error is CancellationError ? .notDownloaded : .failed(error.localizedDescription)
                    self?.qwenTask = nil
                }
            }
        }
    }

    func cancelQwen() {
        qwenTask?.cancel()
        qwenTask = nil
        qwenState = Self.qwenPathIfPresent() != nil ? .ready : .notDownloaded
    }

    func deleteQwen() {
        cancelQwen()
        Task { await LiveCaptionQwenEngine.shared.unload() }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(Self.qwenFileName))
        qwenState = .notDownloaded
    }
}

/// Large-file download with progress + cancellation (Qwen GGUF ~1.1 GB).
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let dest: URL
    private let progress: @Sendable (Double) -> Void
    private var lastReport = Date.distantPast

    private init(dest: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.dest = dest
        self.progress = progress
    }

    static func download(_ url: URL, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let d = FileDownloader(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : LiveCaptionModelStore.qwenExpectedBytes
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = now
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        continuation = nil
    }
}
