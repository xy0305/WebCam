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
                // 仍在写入的 .part 不进列表；已中断的会在恢复后去掉 .part 后缀。
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
    /// 正在录制的目录必须排除，否则会把还在写盘的分片挪走，看起来像录像丢了。
    static func recoverInterruptedRecordings(excludingStems stems: [String] = []) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let skip = Set(stems.map { $0.lowercased() })
        for dir in dirs where dir.pathExtension.lowercased() == "part" {
            let stem = String(dir.lastPathComponent.dropLast(5)).lowercased()
            if skip.contains(stem) { continue }
            _ = promotePartDirectory(dir)
        }
    }

    /// 停止/封装/杀进程前先把 `.part` 变成列表可见的恢复录像，避免唯一副本藏在隐藏目录里。
    @discardableResult
    static func promotePartDirectory(_ dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        let isPart = dir.pathExtension.lowercased() == "part"
        let work = isPart ? dir : dir
        guard ensurePlayableIndex(in: work) else { return isPart ? nil : dir }
        guard isPart else { return dir }

        let base = String(dir.lastPathComponent.dropLast(5))
        var destination = dir.deletingLastPathComponent().appendingPathComponent(base + "_恢复录像", isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = dir.deletingLastPathComponent().appendingPathComponent("\(base)_恢复录像_\(suffix)", isDirectory: true)
            suffix += 1
        }
        do {
            try fm.moveItem(at: dir, to: destination)
            return destination
        } catch {
            return fm.fileExists(atPath: destination.path) ? destination : dir
        }
    }

    /// 有分片但没主清单时补一份，让恢复录像能进列表。
    @discardableResult
    static func ensurePlayableIndex(in dir: URL) -> Bool {
        let fm = FileManager.default
        let index = dir.appendingPathComponent("index.m3u8")
        let video = dir.appendingPathComponent("video.m3u8")
        if fileHasBytes(index) || fileHasBytes(video) {
            if !fileHasBytes(index) {
                writeFallbackIndex(in: dir, hasAudio: fm.fileExists(atPath: dir.appendingPathComponent("audio.m3u8").path))
            }
            return true
        }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let clips = files.filter {
            let n = $0.lastPathComponent.lowercased()
            return n.hasPrefix("v-") && (n.hasSuffix(".m4s") || n.hasSuffix(".ts") || n.hasSuffix(".mp4"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !clips.isEmpty else { return false }

        var body = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        let initFile = dir.appendingPathComponent("v-init.mp4")
        if fm.fileExists(atPath: initFile.path) {
            body += "#EXT-X-MAP:URI=\"v-init.mp4\"\n"
        }
        for clip in clips {
            body += "#EXTINF:2.000,\n\(clip.lastPathComponent)\n"
        }
        body += "#EXT-X-ENDLIST\n"
        try? body.write(to: video, atomically: true, encoding: .utf8)
        writeFallbackIndex(in: dir, hasAudio: false)
        return fileHasBytes(index) || fileHasBytes(video)
    }

    private static func writeFallbackIndex(in dir: URL, hasAudio: Bool) {
        let text: String
        if hasAudio {
            text = """
            #EXTM3U
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO="aud"
            video.m3u8

            """
        } else {
            text = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=5000000
            video.m3u8

            """
        }
        try? text.write(to: dir.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    }

    private static func fileHasBytes(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    static func displayName(_ url: URL) -> String {
        exportFileStem(from: url)
    }

    /// 封装后必须能播才允许删 HLS。半成品 MP4（缺 moov）不能当成功。
    static func isUsableVideoFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 64 * 1024 else { return false }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 8 else {
            return false
        }
        let ftyp = Data("ftyp".utf8)
        let moov = Data("moov".utf8)
        guard data.subdata(in: 4..<8) == ftyp else { return false }
        return data.range(of: moov) != nil
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
            if isTemporary {
                // 空壳 / 封装失败残留直接删；有内容且无法进列表的 .part 先尝试提升为恢复录像。
                if name.hasSuffix(".part") {
                    if promotePartDirectory(url) == nil {
                        try? fm.removeItem(at: url)
                    }
                } else {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// 清理隐藏录制缓存 + 系统/播放器缓存，返回释放前后的粗略体积描述。
    @discardableResult
    static func sweepHiddenCaches(excludingActiveUsernames active: [String], excludingStems stems: [String] = []) -> String {
        let before = hiddenBytes(excludingActiveUsernames: active, excludingStems: stems)
            + Int64(URLCache.shared.currentDiskUsage)
            + tempLeftoverBytes()
        purgeTemporary(excludingActiveUsernames: active, excludingStems: stems)
        URLCache.shared.removeAllCachedResponses()
        clearTemporaryLeftovers()
        let after = hiddenBytes(excludingActiveUsernames: active, excludingStems: stems)
            + Int64(URLCache.shared.currentDiskUsage)
            + tempLeftoverBytes()
        let freed = max(0, before - after)
        return freed > 0 ? "已清理隐藏缓存，约释放 \(formatBytes(freed))" : "没有发现可清理的隐藏缓存"
    }

    /// 录像目录里列表看不见、但占空间的部分（.part / .mux. / 临时轨）。
    static func hiddenBytes(excludingActiveUsernames active: [String], excludingStems stems: [String] = []) -> Int64 {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var total: Int64 = 0
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            if isActivePart(name, usernames: active, stems: stems) { continue }
            let hidden = name.hasSuffix(".part") || name.contains(".mux.") || name.contains("_v.") || name.contains("_a.")
            if hidden { total += folderOrFileSize(url) }
        }
        return total
    }

    /// 录像目录总占用（含列表可见与隐藏）。
    static func libraryBytes() -> Int64 {
        folderSize(directory)
    }

    static func cacheBytes() -> Int64 {
        Int64(URLCache.shared.currentDiskUsage) + tempLeftoverBytes()
    }

    static func formatBytes(_ n: Int64) -> String {
        if n >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(n) / 1_073_741_824)
        }
        if n >= 1_048_576 {
            return String(format: "%.1f MB", Double(n) / 1_048_576)
        }
        return String(format: "%.0f KB", Double(n) / 1024)
    }

    private static func folderOrFileSize(_ url: URL) -> Int64 {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDir ? folderSize(url) : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func tempLeftoverBytes() -> Int64 {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var total: Int64 = 0
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            if name.contains("album-export") || name.contains(".mux.") || name.hasPrefix("115-") {
                total += folderOrFileSize(url)
            }
        }
        return total
    }

    private static func clearTemporaryLeftovers() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            if name.contains("album-export") || name.contains(".mux.") || name.hasPrefix("115-") {
                try? fm.removeItem(at: url)
            }
        }
        // 相册导出等中途崩溃留下的散装 mp4
        let leftovers = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for url in leftovers where url.pathExtension.lowercased() == "mp4" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: url) }
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
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(exportFileStem(from: url)).album-export.\(UUID().uuidString).mp4")
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
