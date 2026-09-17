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
                if url.pathExtension.lowercased() == "part" { continue }
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

    /// 将系统中断后遗留的 .part HLS 目录变成可播放、可导出、可删除的恢复录像。
    static func recoverInterruptedRecordings() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where dir.pathExtension.lowercased() == "part" {
            let index = dir.appendingPathComponent("index.m3u8")
            guard fm.fileExists(atPath: index.path),
                  ((try? index.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { continue }
            let base = String(dir.lastPathComponent.dropLast(5))
            var destination = dir.deletingLastPathComponent().appendingPathComponent(base + "_恢复录像", isDirectory: true)
            var suffix = 2
            while fm.fileExists(atPath: destination.path) {
                destination = dir.deletingLastPathComponent().appendingPathComponent("\(base)_恢复录像_\(suffix)", isDirectory: true)
                suffix += 1
            }
            try? fm.moveItem(at: dir, to: destination)
        }
    }

    static func displayName(_ url: URL) -> String {
        exportFileStem(from: url)
    }

    /// 录像 / 分享 / 相册：`主播名_yyyy-MM-dd_HHmmss`
    static func makeRecordingStem(displayName: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let stem = "\(sanitizeFileName(displayName))_\(f.string(from: date))"
        return uniqueStem(stem)
    }

    /// 从已有录像路径取出可当文件名的「主播名_日期」，去掉恢复/导出后缀。
    static func exportFileStem(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if url.lastPathComponent.lowercased() == "index.m3u8" {
            name = url.deletingLastPathComponent().lastPathComponent
        }
        for token in [".album-export", "_恢复录像"] {
            if let range = name.range(of: token, options: .caseInsensitive) {
                name.removeSubrange(range)
            }
        }
        if let range = name.range(of: #"_\d+$"#, options: .regularExpression),
           name.contains("_恢复录像") {
            name.removeSubrange(range)
        }
        if name.hasSuffix("_") { name = String(name.dropLast()) }
        return sanitizeFileName(name.isEmpty ? "recording" : name)
    }

    static func shareURL(for url: URL) -> URL {
        if url.lastPathComponent.lowercased() == "index.m3u8" { return url }
        let stem = exportFileStem(from: url)
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let named = url.deletingLastPathComponent().appendingPathComponent("\(stem).\(ext)")
        if named.path == url.path { return url }
        if FileManager.default.fileExists(atPath: named.path) { return named }
        try? FileManager.default.copyItem(at: url, to: named)
        return FileManager.default.fileExists(atPath: named.path) ? named : url
    }

    static func sanitizeFileName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
            .union(.controlCharacters)
        s = s.components(separatedBy: invalid).joined(separator: "_")
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        if s.isEmpty { s = "recording" }
        if s.count > 80 { s = String(s.prefix(80)) }
        return s
    }

    private static func uniqueStem(_ stem: String) -> String {
        let fm = FileManager.default
        func exists(_ base: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(base + ".part").path)
                || fm.fileExists(atPath: directory.appendingPathComponent(base + ".mp4").path)
                || fm.fileExists(atPath: directory.appendingPathComponent(base + "_恢复录像").path)
        }
        if !exists(stem) { return stem }
        var n = 2
        while exists("\(stem)_\(n)") { n += 1 }
        return "\(stem)_\(n)"
    }

    private static func isActivePart(_ filename: String, usernames: [String], stems: [String]) -> Bool {
        let name = filename.lowercased()
        guard name.hasSuffix(".part") else { return false }
        let stem = String(name.dropLast(5))
        if stems.contains(where: { $0.lowercased() == stem }) { return true }
        return usernames.contains { stem.hasPrefix($0.lowercased() + "_") }
    }

    static func delete(_ url: URL) {
        if url.lastPathComponent.lowercased() == "index.m3u8" {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 删除全部已保存录像及遗留的录制缓存；仍在录制的 .part 目录会被保留。
    static func clearAll(excludingActiveUsernames active: [String], excludingStems stems: [String] = []) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            if isActivePart(url.lastPathComponent, usernames: active, stems: stems) { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// 导出成功后清理不会出现在录像列表里的原始分片与失败封装残留。
    static func purgeTemporary(excludingActiveUsernames active: [String], excludingStems stems: [String] = []) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            if isActivePart(name, usernames: active, stems: stems) { continue }
            let isTemporary = name.hasSuffix(".part") || name.contains(".mux.") || name.contains("_v.") || name.contains("_a.")
            if isTemporary { try? fm.removeItem(at: url) }
        }
    }

    enum AlbumPreparationError: LocalizedError {
        case muxFailed
        var errorDescription: String? { "恢复录像封装 MP4 失败，原始分片已保留" }
    }

    /// 将列表中的恢复 HLS 录像封装为临时 MP4；普通 MP4/MOV 直接返回原文件。
    static func prepareForAlbumExport(_ url: URL) async throws -> (file: URL, cleanup: Bool) {
        guard url.lastPathComponent.lowercased() == "index.m3u8" else {
            return (url, false)
        }
        let folder = url.deletingLastPathComponent()
        finalizeRecoveredPlaylists(in: folder)
        let output = folder.deletingLastPathComponent()
            .appendingPathComponent(exportFileStem(from: url) + ".mp4")
        try? FileManager.default.removeItem(at: output)
        var ok = await Task.detached(priority: .utility) {
            FFmpegLocalMuxer.mux(input: url, output: output)
        }.value
        if !ok {
            try? FileManager.default.removeItem(at: output)
            let video = folder.appendingPathComponent("video.m3u8")
            ok = await Task.detached(priority: .utility) {
                FFmpegLocalMuxer.mux(input: video, output: output)
            }.value
        }
        guard ok, FileManager.default.fileExists(atPath: output.path) else {
            throw AlbumPreparationError.muxFailed
        }
        return (output, true)
    }

    private static func finalizeRecoveredPlaylists(in folder: URL) {
        for name in ["video.m3u8", "audio.m3u8"] {
            let url = folder.appendingPathComponent(name)
            guard var text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            text = text.replacingOccurrences(of: "#EXT-X-PLAYLIST-TYPE:EVENT", with: "#EXT-X-PLAYLIST-TYPE:VOD")
            if !text.contains("#EXT-X-ENDLIST") {
                text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n#EXT-X-ENDLIST\n"
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let index = folder.appendingPathComponent("index.m3u8")
        if var text = try? String(contentsOf: index, encoding: .utf8), !text.contains("#EXT-X-ENDLIST") {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n#EXT-X-ENDLIST\n"
            try? text.write(to: index, atomically: true, encoding: .utf8)
        }
    }

    static func finishAlbumExport(source: URL, exportedFile: URL, cleanup: Bool) {
        guard cleanup else { return }
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: exportedFile)
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
