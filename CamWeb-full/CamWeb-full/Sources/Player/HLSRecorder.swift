import Foundation
import UIKit

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

        let name = username
        let startURL = hlsURL
        task = Task { [weak self] in
            var playlistURL = startURL
            var seen = Set<String>()
            while let self, !Task.isCancelled, self.isRecording {
                do {
                    var current = playlistURL
                    var text = try await HLSFetcher.text(current)
                    if text.contains("#EXT-X-STREAM-INF"), let variant = HLSFetcher.pickVariant(text, base: current) {
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

    func stop() {
        task?.cancel()
        task = nil
        isRecording = false
        stopTimer()
        UIApplication.shared.isIdleTimerDisabled = false
        try? fileHandle?.close()
        fileHandle = nil
        if written > 0 {
            alert = "已保存到录像"
        } else {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            alert = "没有写到数据"
        }
        outputURL = nil
        written = 0
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
