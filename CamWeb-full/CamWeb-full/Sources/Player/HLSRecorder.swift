import Foundation
import UIKit

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

    func start(username: String, hlsURL: URL) {
        let name = username.lowercased()
        guard sessions[name] == nil else { return }
        let session = RecordingSession(username: name, hlsURL: hlsURL)
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

    func toggle(username: String, hlsURL: URL) {
        if isRecording(username) {
            stop(username)
        } else {
            start(username: username, hlsURL: hlsURL)
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

@MainActor
final class RecordingSession: ObservableObject, Identifiable {
    var id: String { username }
    let username: String
    let hlsURL: URL

    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var isRunning = false

    var onFinished: ((String, String) -> Void)?

    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var outputURL: URL?
    private var fileHandle: FileHandle?
    private var written: Int64 = 0

    init(username: String, hlsURL: URL) {
        self.username = username
        self.hlsURL = hlsURL
    }

    func start() {
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(username)_\(Self.stamp()).ts")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        outputURL = url
        fileHandle = try? FileHandle(forWritingTo: url)
        written = 0
        isRunning = true
        startedAt = Date()
        startTimer()

        let name = username
        let startURL = hlsURL
        task = Task { [weak self] in
            var playlistURL = startURL
            var seen = Set<String>()
            while let self, !Task.isCancelled, self.isRunning {
                do {
                    var current = playlistURL
                    var text = try await HLSFetcher.text(current)
                    if text.contains("#EXT-X-STREAM-INF"),
                       let variant = HLSFetcher.pickVariant(text, base: current) {
                        current = variant
                        playlistURL = variant
                        text = try await HLSFetcher.text(current)
                    }
                    for seg in HLSFetcher.parseSegments(text, base: current) where !seen.contains(seg.absoluteString) {
                        seen.insert(seg.absoluteString)
                        let data = try await HLSFetcher.data(seg)
                        self.append(data)
                    }
                } catch {
                    if Task.isCancelled { break }
                    if let fresh = try? await StreamSource.resolve(username: name) {
                        playlistURL = fresh.hlsURL
                        seen.removeAll()
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    func stop(userInitiated: Bool) {
        task?.cancel()
        task = nil
        isRunning = false
        stopTimer()
        try? fileHandle?.close()
        fileHandle = nil
        let message: String
        if written > 0 {
            message = "\(username) 已保存 \(bytesText)"
        } else {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            message = "\(username) 没有写到数据"
        }
        outputURL = nil
        written = 0
        onFinished?(username, message)
    }

    private func append(_ data: Data) {
        fileHandle?.write(data)
        written += Int64(data.count)
        bytesText = String(format: "%.1f MB", Double(written) / 1_048_576)
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

enum HLSFetcher {
    static func text(_ url: URL) async throws -> String {
        String(data: try await data(url), encoding: .utf8) ?? ""
    }

    static func data(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in APIClient.commonHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StreamSourceError.badResponse
        }
        return data
    }

    static func pickVariant(_ playlist: String, base: URL) -> URL? {
        var bestURL: URL?
        var bestBW = -1
        var pendingBW = 0
        for line in playlist.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBW = 0
                if let r = line.range(of: "BANDWIDTH=") {
                    pendingBW = Int(line[r.upperBound...].prefix(while: { $0.isNumber })) ?? 0
                }
            } else if !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if pendingBW >= bestBW, let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    bestBW = pendingBW
                    bestURL = url
                }
                pendingBW = 0
            }
        }
        return bestURL
    }

    static func parseSegments(_ playlist: String, base: URL) -> [URL] {
        playlist.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return URL(string: line, relativeTo: base)?.absoluteURL
        }
    }
}
