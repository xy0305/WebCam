import Foundation

enum RecordingStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func list() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var out: [URL] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let index = url.appendingPathComponent("index.m3u8")
                if fm.fileExists(atPath: index.path) {
                    out.append(index)
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent.lowercased()
            guard ["mov", "mp4", "ts"].contains(ext) else { continue }
            if name.contains(".mux.") || name.hasSuffix(".part") || name.contains("_v.") || name.contains("_a.") {
                continue
            }
            out.append(url)
        }
        return out.sorted { a, b in
            created(a) > created(b)
        }
    }

    static func displayName(_ url: URL) -> String {
        if url.lastPathComponent.lowercased() == "index.m3u8" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func delete(_ url: URL) {
        if url.lastPathComponent.lowercased() == "index.m3u8" {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func sizeText(_ url: URL) -> String {
        let n = byteSize(url)
        if n >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(n) / 1_073_741_824)
        }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }

    private static func byteSize(_ url: URL) -> Int64 {
        if url.lastPathComponent.lowercased() == "index.m3u8" {
            return folderSize(url.deletingLastPathComponent())
        }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func folderSize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in en {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func created(_ url: URL) -> Date {
        let target = url.lastPathComponent.lowercased() == "index.m3u8" ? url.deletingLastPathComponent() : url
        return (try? target.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
