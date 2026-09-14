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
                // 录制/封装中的目录不提供播放或分享，避免把 m3u8 当文本导出。
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
    /// 不删除任何分片，避免切后台时已经录到的内容凭空消失。
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

    /// 删除全部已保存录像及遗留的录制缓存；仍在录制的 .part 目录会被保留。
    static func clearAll(excludingActiveUsernames active: [String]) {
        let fm = FileManager.default
        let activeNames = Set(active.map { $0.lowercased() })
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            let isActivePart = name.hasSuffix(".part") && activeNames.contains { name.hasPrefix("\($0)_") }
            if !isActivePart { try? fm.removeItem(at: url) }
        }
    }

    /// 导出成功后清理不会出现在录像列表里的原始分片与失败封装残留。
    /// 活跃任务的 .part 目录绝不触碰。
    static func purgeTemporary(excludingActiveUsernames active: [String]) {
        let fm = FileManager.default
        let activeNames = Set(active.map { $0.lowercased() })
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            let isActivePart = name.hasSuffix(".part") && activeNames.contains { name.hasPrefix("\($0)_") }
            let isTemporary = name.hasSuffix(".part") || name.contains(".mux.") || name.contains("_v.") || name.contains("_a.")
            if isTemporary && !isActivePart { try? fm.removeItem(at: url) }
        }
    }

    enum AlbumPreparationError: LocalizedError {
        case muxFailed
        var errorDescription: String? { "恢复录像封装 MP4 失败，原始分片已保留" }
    }

    /// 将列表中的恢复 HLS 录像封装为临时 MP4；普通 MP4/MOV 直接返回原文件。
    /// 返回的 cleanup 为 true 时，相册保存成功后应删除原恢复目录和临时 MP4。
    static func prepareForAlbumExport(_ url: URL) async throws -> (file: URL, cleanup: Bool) {
        guard url.lastPathComponent.lowercased() == "index.m3u8" else {
            return (url, false)
        }
        let folder = url.deletingLastPathComponent()
        finalizeRecoveredPlaylists(in: folder)
        let output = folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent + ".album-export.mp4")
        try? FileManager.default.removeItem(at: output)
        var ok = await Task.detached(priority: .utility) {
            FFmpegLocalMuxer.mux(input: url, output: output)
        }.value
        // 少数旧恢复目录的主清单含有不完整音频轨；至少导出完整视频而不是直接失败。
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

    /// 系统中断时清单可能是 EVENT 且没有 ENDLIST；导出前将已有分片封口为 VOD。
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
        // 主清单本身也补 ENDLIST，兼容更严格的 HLS 解复用器。
        let index = folder.appendingPathComponent("index.m3u8")
        if var text = try? String(contentsOf: index, encoding: .utf8), !text.contains("#EXT-X-ENDLIST") {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n#EXT-X-ENDLIST\n"
            try? text.write(to: index, atomically: true, encoding: .utf8)
        }
    }

    /// 在恢复录像已保存到相册后删除原始分片和临时 MP4。
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
