import Foundation
import UIKit

/// Downloads live HLS segments and appends them as-is (source copy, no re-encode).
@MainActor
final class HLSRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsedText = "00:00"
    @Published var bytesText = "0 MB"
    @Published var alert: String?

    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var outputURL: URL?
    private var fileHandle: FileHandle?
    private var written: Int64 = 0

    func start(username: String, hlsURL: URL) {
        guard !isRecording else { return }
        let dir = RecordingStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(username)_\(Self.stamp()).ts")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        outputURL = url
        fileHandle = try? FileHandle(forWritingTo: url)
        written = 0
        isRecording = true
        startedAt = Date()
        elapsedText = "00:00"
        bytesText = "0 MB"
        startTimer()
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task.detached { [weak self] in
            await Self.pump(username: username, startURL: hlsURL, recorder: self)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRecording = false
        stopTimer()
        UIApplication.shared.isIdleTimerDisabled = false
        try? fileHandle?.close()
        fileHandle = nil
        if written > 0 {
            alert = "Saved source stream to Recordings."
        } else {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            alert = "No media was written."
        }
        outputURL = nil
        written = 0
    }

    fileprivate func append(_ data: Data) {
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

    nonisolated private static func pump(username: String, startURL: URL, recorder: HLSRecorder?) async {
        var playlistURL = startURL
        var seen = Set<String>()
        while !Task.isCancelled {
            do {
                var current = playlistURL
                var text = try await fetchText(current)
                if text.contains("#EXT-X-STREAM-INF") {
                    if let variant = pickVariant(text, base: current) {
                        current = variant
                        playlistURL = variant
                        text = try await fetchText(current)
                    }
                }
                let segs = parseSegments(text, base: current)
                for seg in segs where !seen.contains(seg.absoluteString) {
                    seen.insert(seg.absoluteString)
                    let data = try await fetchData(seg)
                    await MainActor.run { recorder?.append(data) }
                }
            } catch {
                if Task.isCancelled { break }
                if let fresh = try? await StreamSource.resolve(username: username) {
                    playlistURL = fresh.hlsURL
                    seen.removeAll()
                }
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    nonisolated private static func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func fetchData(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in APIClient.commonHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StreamSourceError.badResponse
        }
        return data
    }

    nonisolated private static func pickVariant(_ playlist: String, base: URL) -> URL? {
        var bestURL: URL?
        var bestBW = -1
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pendingBW = 0
        for line in lines {
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

    nonisolated private static func parseSegments(_ playlist: String, base: URL) -> [URL] {
        playlist.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return URL(string: line, relativeTo: base)?.absoluteURL
        }
    }
}
