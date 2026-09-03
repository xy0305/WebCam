import Foundation

enum RecordingStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter {
                let ext = $0.pathExtension.lowercased()
                let name = $0.lastPathComponent.lowercased()
                guard ["mov", "mp4", "ts", "m4s", "m3u8"].contains(ext) else { return false }
                return !name.contains(".mux.") && !name.hasSuffix(".part") && !name.contains("_v.") && !name.contains("_a.")
            }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func sizeText(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}
