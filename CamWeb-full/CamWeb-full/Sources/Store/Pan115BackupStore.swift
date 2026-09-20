import Darwin
import Foundation
import Photos
import UIKit

@MainActor
final class Pan115BackupStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = Pan115BackupStore()

    @Published private(set) var tasks: [Pan115BackupTask] = []
    @Published private(set) var scanningIDs: Set<UUID> = []
    @Published private(set) var progress: [UUID: ScanProgress] = [:]

    struct ScanProgress: Equatable {
        var phase: String = "准备"
        var total: Int = 0
        var index: Int = 0
        var queued: Int = 0
        var skipped: Int = 0
        var current: String = ""
        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(index) / Double(total))
        }
    }

    private var monitors: [UUID: DispatchSourceFileSystemObject] = [:]
    private var access: [UUID: URL] = [:]
    private var scanTimer: Timer?
    private var scheduleTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var photoObserverOn = false
    private let fm = FileManager.default

    private var storeURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("115-backups.json")
    }

    private func manifestURL(_ id: UUID) -> URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("115-backup-\(id.uuidString).json")
    }

    private override init() {
        super.init()
        tasks = Self.load(storeURL)
        startTimers()
        tasks.filter(\.enabled).forEach { startMonitor($0) }
        for task in tasks where task.enabled && task.forceScanOnLaunch {
            enqueueScan(task.id, reason: "启动扫描")
        }
    }

    func keepAlive() {
        if tasks.contains(where: { $0.enabled }) { extendBackground() }
    }

    func save(_ draft: Pan115BackupTask, isNew: Bool) {
        var task = draft
        if task.name.trimmingCharacters(in: .whitespaces).isEmpty {
            task.name = task.sourceName.isEmpty ? "未命名备份" : task.sourceName
        }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            stopMonitor(task.id)
            tasks[i] = task
        } else {
            tasks.insert(task, at: 0)
        }
        persist()
        if task.enabled {
            startMonitor(task)
            if isNew && task.scanOnCreate {
                enqueueScan(task.id, reason: "创建后扫描")
            }
        }
    }

    func delete(_ id: UUID) {
        stopMonitor(id)
        tasks.removeAll { $0.id == id }
        try? fm.removeItem(at: manifestURL(id))
        persist()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        update(id) { $0.enabled = on }
        if on {
            if let task = tasks.first(where: { $0.id == id }) { startMonitor(task) }
        } else {
            stopMonitor(id)
        }
    }

    func scanNow(_ id: UUID) { enqueueScan(id, reason: "手动扫描") }

    func bookmark(from url: URL) -> (data: Data, path: String, name: String)? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.nameKey], relativeTo: nil) else { return nil }
        return (data, url.path, url.lastPathComponent)
    }

    func resolve(_ task: Pan115BackupTask) -> URL? {
        guard !task.sourceBookmark.isEmpty else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: task.sourceBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        access[task.id] = url
        return url
    }

    private func enqueueScan(_ id: UUID, reason: String) {
        guard let task = tasks.first(where: { $0.id == id }), task.enabled else { return }
        guard !scanningIDs.contains(id) else { return }
        scanningIDs.insert(id)
        progress[id] = ScanProgress(phase: reason, total: 0, index: 0, queued: 0, skipped: 0, current: "")
        update(id, persistNow: false) { $0.lastMessage = reason; $0.lastError = nil }
        extendBackground()
        Task { await scan(id) }
    }

    private func scan(_ id: UUID) async {
        defer {
            scanningIDs.remove(id)
            progress.removeValue(forKey: id)
            persist()
        }
        guard var task = tasks.first(where: { $0.id == id }) else { return }
        guard Pan115Session.shared.hasCookie else {
            update(id) { $0.lastError = "115 未登录"; $0.lastMessage = "115 未登录" }
            return
        }
        let dests = task.enabledDestinations
        guard !dests.isEmpty else {
            update(id) { $0.lastError = "未配置目标位置"; $0.lastMessage = "未配置目标位置" }
            return
        }
        var manifest = loadManifest(id)
        let locals: [LocalFile]
        if task.sourceKind == .photos {
            do {
                try await scanPhotoLibrary(id: id, task: task, dests: dests, manifest: &manifest)
            } catch {
                update(id) { $0.lastError = error.localizedDescription; $0.lastMessage = error.localizedDescription }
            }
            return
        } else {
            guard let root = resolve(task) else {
                update(id) { $0.lastError = "无法打开源文件夹，请重新选择"; $0.lastMessage = "无法打开源文件夹" }
                return
            }
            setProgress(id, phase: "列举文件", total: 0, index: 0, queued: 0, skipped: 0, current: root.lastPathComponent)
            locals = listLocal(root: root)
        }
        var uploaded = 0
        var skipped = 0
        var lastErr: String?
        setProgress(id, phase: "扫描文件夹", total: locals.count, index: 0, queued: 0, skipped: 0, current: "")

        for (offset, file) in locals.enumerated() {
            setProgress(id, index: offset + 1, current: file.name)
            guard task.allows(fileName: file.rel) else {
                skipped += 1
                setProgress(id, skipped: skipped)
                continue
            }
            let key = file.rel
            let prev = manifest.items[key]
            let unchanged = prev != nil && prev?.size == file.size && abs((prev?.mtime ?? 0) - file.mtime) < 1
            for dest in dests {
                if unchanged, task.existPolicy == .skip, prev?.destIDs.contains(dest.id.uuidString) == true {
                    skipped += 1
                    continue
                }
                do {
                    let cid = try await Pan115API.driveEnsureFolder(parent: dest.cid, parts: file.folders)
                    if task.existPolicy == .skip {
                        let kids = try await Pan115API.driveList(cid: cid)
                        if kids.contains(where: { !$0.isDir && $0.name == file.name }) {
                            skipped += 1
                            var item = manifest.items[key] ?? .init(relativePath: key, size: file.size, mtime: file.mtime, destIDs: [])
                            if !item.destIDs.contains(dest.id.uuidString) { item.destIDs.append(dest.id.uuidString) }
                            manifest.items[key] = item
                            continue
                        }
                    }
                    var name = file.name
                    if task.existPolicy == .rename {
                        let kids = try await Pan115API.driveList(cid: cid)
                        if kids.contains(where: { !$0.isDir && $0.name == name }) {
                            name = rename(file.name)
                        }
                    }
                    if Pan115Uploader.shared.isQueued(name: name, cid: cid) {
                        skipped += 1
                        setProgress(id, skipped: skipped)
                        continue
                    }
                    let bookmark = try? file.url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    Pan115Uploader.shared.enqueue(
                        fileURL: file.url,
                        name: name,
                        size: file.size,
                        cid: cid,
                        folderName: dest.name,
                        ownsFile: false,
                        bookmark: bookmark
                    )
                    uploaded += 1
                    setProgress(id, queued: uploaded)
                    var item = Pan115BackupManifest.Item(relativePath: key, size: file.size, mtime: file.mtime, destIDs: prev?.destIDs ?? [])
                    if !item.destIDs.contains(dest.id.uuidString) { item.destIDs.append(dest.id.uuidString) }
                    manifest.items[key] = item
                    if task.afterBackup == .deleteSource, task.sourceKind != .photos {
                        try? fm.removeItem(at: file.url)
                    }
                } catch {
                    lastErr = error.localizedDescription
                }
            }
        }

        if task.sourceDeletedPolicy == .deleteRemote, task.sourceKind != .photos {
            let localKeys = Set(locals.map(\.rel))
            for (key, item) in manifest.items where !localKeys.contains(key) {
                for dest in dests {
                    do {
                        let cid = try await Pan115API.driveEnsureFolder(
                            parent: dest.cid,
                            parts: URL(fileURLWithPath: key).deletingLastPathComponent().path.split(separator: "/").map(String.init)
                        )
                        let kids = try await Pan115API.driveList(cid: cid)
                        let name = URL(fileURLWithPath: key).lastPathComponent
                        if let hit = kids.first(where: { !$0.isDir && $0.name == name }) {
                            try await Pan115API.driveDelete(id: hit.id)
                        }
                    } catch {
                        lastErr = error.localizedDescription
                    }
                }
                manifest.items.removeValue(forKey: key)
            }
        }

        if task.syncDeleteFromDest, task.sourceKind != .photos {
            for file in locals {
                for dest in dests {
                    do {
                        let cid = try await Pan115API.driveEnsureFolder(parent: dest.cid, parts: file.folders)
                        let kids = try await Pan115API.driveList(cid: cid)
                        if !kids.contains(where: { !$0.isDir && $0.name == file.name }) {
                            try? fm.removeItem(at: file.url)
                            manifest.items.removeValue(forKey: file.rel)
                        }
                    } catch {
                        lastErr = error.localizedDescription
                    }
                }
            }
        }

        saveManifest(id, manifest)
        update(id) {
            $0.lastScanAt = Date()
            $0.lastError = lastErr
            $0.lastMessage = lastErr ?? "完成：上传 \(uploaded)，跳过 \(skipped)"
            $0.uploadedCount += uploaded
            $0.skippedCount += skipped
        }
    }

    private struct LocalFile {
        var url: URL
        var rel: String
        var name: String
        var folders: [String]
        var size: Int64
        var mtime: TimeInterval
    }

    private func listLocal(root: URL) -> [LocalFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [LocalFile] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true { continue }
            if rv?.isHidden == true { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var rel = String(path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty else { continue }
            let parts = rel.split(separator: "/").map(String.init)
            let name = parts.last ?? url.lastPathComponent
            let folders = Array(parts.dropLast())
            out.append(LocalFile(
                url: url,
                rel: rel,
                name: name,
                folders: folders,
                size: Int64(rv?.fileSize ?? 0),
                mtime: rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return out
    }

    private func scanPhotoLibrary(id: UUID, task: Pan115BackupTask, dests: [Pan115BackupTask.Destination], manifest: inout Pan115BackupManifest) async throws {
        setProgress(id, phase: "请求相册权限", total: 0, index: 0, queued: 0, skipped: 0, current: "")
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw Pan115API.APIError.message("没有相册权限，请在系统设置里允许读取照片")
        }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: opts)
        let total = result.count
        setProgress(id, phase: "扫描相册", total: total, index: 0, queued: 0, skipped: 0, current: "共 \(total) 项")
        var queued = 0
        var skipped = 0
        let lastErr: String? = nil
        let limit = min(total, 8000)
        for i in 0..<limit {
            await Task.yield()
            let asset = result.object(at: i)
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = preferredResource(resources) else {
                skipped += 1
                setProgress(id, index: i + 1, skipped: skipped, current: "跳过无资源项")
                continue
            }
            let name = resource.originalFilename
            setProgress(id, phase: "扫描相册", total: total, index: i + 1, queued: queued, skipped: skipped, current: name)
            guard task.allows(fileName: name) else {
                skipped += 1
                setProgress(id, skipped: skipped)
                continue
            }
            let mtime = (asset.modificationDate ?? asset.creationDate ?? Date()).timeIntervalSince1970
            let key = "\(asset.localIdentifier)|\(name)"
            if let prev = manifest.items[key], abs(prev.mtime - mtime) < 2, task.existPolicy == .skip {
                skipped += 1
                setProgress(id, skipped: skipped, current: "已备份 \(name)")
                continue
            }
            let sizeHint = Int64(resource.value(forKey: "fileSize") as? Int ?? 0)
            for dest in dests {
                if Pan115Uploader.shared.isQueued(name: name, cid: dest.cid) {
                    skipped += 1
                    continue
                }
                var uploadName = name
                if task.existPolicy == .rename, manifest.items[key]?.destIDs.contains(dest.id.uuidString) == true {
                    uploadName = rename(name)
                }
                Pan115Uploader.shared.enqueue(
                    fileURL: URL(fileURLWithPath: "/photos/\(asset.localIdentifier)"),
                    name: uploadName,
                    size: max(sizeHint, 1),
                    cid: dest.cid,
                    folderName: dest.name,
                    ownsFile: false,
                    photoAssetID: asset.localIdentifier
                )
                queued += 1
                var item = Pan115BackupManifest.Item(relativePath: key, size: sizeHint, mtime: mtime, destIDs: manifest.items[key]?.destIDs ?? [])
                if !item.destIDs.contains(dest.id.uuidString) { item.destIDs.append(dest.id.uuidString) }
                manifest.items[key] = item
            }
            setProgress(id, queued: queued, skipped: skipped, current: name)
            if i % 15 == 0 { saveManifest(id, manifest) }
        }
        saveManifest(id, manifest)
        update(id) {
            $0.lastScanAt = Date()
            $0.lastError = lastErr
            $0.lastMessage = lastErr ?? "扫描完成：加入上传 \(queued)，跳过 \(skipped)，共 \(total) 项"
            $0.uploadedCount += queued
            $0.skippedCount += skipped
        }
    }

    private func setProgress(_ id: UUID, phase: String? = nil, total: Int? = nil, index: Int? = nil, queued: Int? = nil, skipped: Int? = nil, current: String? = nil) {
        var p = progress[id] ?? ScanProgress()
        if let phase { p.phase = phase }
        if let total { p.total = total }
        if let index { p.index = index }
        if let queued { p.queued = queued }
        if let skipped { p.skipped = skipped }
        if let current { p.current = current }
        progress[id] = p
        update(id, persistNow: false) {
            $0.lastError = nil
            $0.lastMessage = progressLine(p)
        }
    }

    private func progressLine(_ p: ScanProgress) -> String {
        if p.total > 0 {
            let pct = Int(p.fraction * 100)
            let now = p.current.isEmpty ? "" : " · \(p.current)"
            return "\(p.phase) \(p.index)/\(p.total) (\(pct)%) · 已加入 \(p.queued) · 跳过 \(p.skipped)\(now)"
        }
        return p.phase + (p.current.isEmpty ? "" : " · \(p.current)")
    }

    private func preferredResource(_ resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .fullSizeVideo || $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizePhoto || $0.type == .photo })
            ?? resources.first
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            for task in self.tasks where task.enabled && task.sourceKind == .photos && task.fsMonitor {
                self.enqueueScan(task.id, reason: "相册更改")
            }
        }
    }

    private func rename(_ name: String) -> String {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        let stamp = Int(Date().timeIntervalSince1970)
        return ext.isEmpty ? "\(base)_\(stamp)" : "\(base)_\(stamp).\(ext)"
    }

    private func startMonitor(_ task: Pan115BackupTask) {
        stopMonitor(task.id)
        guard task.enabled, task.fsMonitor else { return }
        if task.sourceKind == .photos {
            if !photoObserverOn {
                PHPhotoLibrary.shared().register(self)
                photoObserverOn = true
            }
            return
        }
        guard let url = resolve(task) else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.enqueueScan(task.id, reason: "文件系统更改")
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        monitors[task.id] = src
    }

    private func stopMonitor(_ id: UUID) {
        monitors[id]?.cancel()
        monitors[id] = nil
        if let url = access.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func startTimers() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickScan() }
        }
        scheduleTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSchedule() }
        }
    }

    private func tickScan() {
        let now = Date()
        for task in tasks where task.enabled && task.fullScanInterval > 0 {
            let last = task.lastScanAt ?? .distantPast
            if now.timeIntervalSince(last) >= task.fullScanInterval {
                enqueueScan(task.id, reason: "全量扫描")
            }
        }
    }

    private var lastScheduleFire: String = ""
    private func tickSchedule() {
        let cal = Calendar.current
        let now = Date()
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let key = "\(cal.component(.year, from: now))-\(cal.component(.month, from: now))-\(cal.component(.day, from: now))-\(h)-\(m)"
        guard key != lastScheduleFire else { return }
        for task in tasks where task.enabled && task.scheduleEnabled {
            if task.scheduleHour == h && task.scheduleMinute == m {
                lastScheduleFire = key
                enqueueScan(task.id, reason: "定时任务")
            }
        }
    }

    private func update(_ id: UUID, persistNow: Bool = true, _ body: (inout Pan115BackupTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var t = tasks[i]
        body(&t)
        tasks[i] = t
        if persistNow { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tasks) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private static func load(_ url: URL) -> [Pan115BackupTask] {
        guard var data = try? Data(contentsOf: url) else { return [] }
        if var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            arr = arr.map { row in
                var row = row
                if row["sourceKind"] == nil { row["sourceKind"] = "folder" }
                return row
            }
            if let patched = try? JSONSerialization.data(withJSONObject: arr) { data = patched }
        }
        return (try? JSONDecoder().decode([Pan115BackupTask].self, from: data)) ?? []
    }

    private func loadManifest(_ id: UUID) -> Pan115BackupManifest {
        guard let data = try? Data(contentsOf: manifestURL(id)),
              let m = try? JSONDecoder().decode(Pan115BackupManifest.self, from: data) else {
            return Pan115BackupManifest()
        }
        return m
    }

    private func saveManifest(_ id: UUID, _ m: Pan115BackupManifest) {
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: manifestURL(id), options: .atomic)
        }
    }

    private func extendBackground() {
        if bgTask != .invalid { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "115-backup") { [weak self] in
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

extension Pan115Uploader {
    func isQueued(name: String, cid: String) -> Bool {
        jobs.contains {
            $0.name == name && $0.cid == cid &&
            $0.status != .done && $0.status != .cancelled
        }
    }
}
