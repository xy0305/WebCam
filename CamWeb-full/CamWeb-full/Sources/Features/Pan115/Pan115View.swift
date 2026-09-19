import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct Pan115View: View {
    @ObservedObject private var session = Pan115Session.shared
    @ObservedObject private var uploader = Pan115Uploader.shared
    @ObservedObject private var backups = Pan115BackupStore.shared
    @State private var nodes: [Pan115API.Node] = []
    @State private var path: [(id: String, name: String)] = [("0", "根目录")]
    @State private var loading = false
    @State private var errorText: String?
    @State private var showLogin = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var newFolder = ""
    @State private var showFolder = false
    @State private var tab: Pane = .files
    @State private var searchText = ""
    @State private var searchHits: [Pan115API.Node] = []
    @State private var searching = false
    @State private var pickNotice: String?
    @State private var showBackupEditor = false
    @State private var editingBackup: Pan115BackupTask?
    @State private var showUploadFolder = false
    @State private var playBusy = false
    @State private var showShare = false
    @State private var showRecycle = false
    @State private var showMove = false
    @State private var moveIsCopy = false
    @State private var movingNodes: [Pan115API.Node] = []
    @State private var showRename = false
    @State private var renameTarget: Pan115API.Node?
    @State private var renameText = ""
    @State private var space: Pan115API.SpaceInfo?

    private enum Pane: String, CaseIterable {
        case files = "网盘"
        case upload = "上传"
        case offline = "离线"
        case backup = "备份"
    }

    private var cid: String { path.last?.id ?? "0" }
    private var folderName: String { path.map(\.name).joined(separator: " / ") }
    private var folders: [Pan115API.Node] { nodes.filter(\.isDir) }
    private var files: [Pan115API.Node] { nodes.filter { !$0.isDir } }

    var body: some View {
        NavigationStack {
            rootContent
                .navigationTitle("115")
                .toolbar { toolbar }
                .sheet(isPresented: $showLogin) { Pan115LoginView() }
                .sheet(isPresented: $showBackupEditor, content: backupEditorSheet)
                .sheet(isPresented: $showUploadFolder, content: uploadFolderSheet)
                .sheet(isPresented: $showShare, content: shareSheet)
                .sheet(isPresented: $showRecycle, content: recycleSheet)
                .sheet(isPresented: $showMove, content: moveSheet)
                .alert("新建文件夹", isPresented: $showFolder) {
                    TextField("名称", text: $newFolder)
                    Button("取消", role: .cancel) {}
                    Button("创建") {
                        let name = newFolder
                        newFolder = ""
                        Task { await makeFolder(name) }
                    }
                }
                .alert("重命名", isPresented: $showRename) {
                    TextField("名称", text: $renameText)
                    Button("取消", role: .cancel) { renameTarget = nil }
                    Button("保存") {
                        let name = renameText
                        let target = renameTarget
                        renameTarget = nil
                        Task { await rename(target, name) }
                    }
                }
                .alert("提示", isPresented: Binding(get: { pickNotice != nil }, set: { if !$0 { pickNotice = nil } })) {
                    Button("好", role: .cancel) { pickNotice = nil }
                } message: { Text(pickNotice ?? "") }
                .onChange(of: photos) { _, items in
                    Task { await enqueuePhotos(items); photos = [] }
                }
                .task { if session.hasCookie { await reload() } }
                .onChange(of: session.hasCookie) { _, ok in
                    if ok { Task { await reload() } } else { nodes = []; searchHits = [] }
                }
                .onChange(of: searchText) { _, q in
                    Task { await runSearch(q) }
                }
        }
    }

    private func backupEditorSheet() -> some View {
        Pan115BackupEditor(
            existing: editingBackup,
            onSave: { task in
                backups.save(task, isNew: editingBackup == nil)
                showBackupEditor = false
                tab = .backup
            },
            onCancel: { showBackupEditor = false }
        )
    }

    private func uploadFolderSheet() -> some View {
        Pan115FolderPicker { cid, name in
            session.setUploadFolder(cid: cid, name: name)
            showUploadFolder = false
        } onCancel: {
            showUploadFolder = false
        }
    }

    private func shareSheet() -> some View {
        NavigationStack {
            Pan115ShareView()
                .navigationTitle("转存分享")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showShare = false } } }
        }
    }

    private func recycleSheet() -> some View {
        NavigationStack {
            Pan115RecycleView()
                .navigationTitle("回收站")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showRecycle = false } } }
        }
    }

    private func moveSheet() -> some View {
        Pan115FolderPicker { dest, name in
            showMove = false
            let items = movingNodes
            let copy = moveIsCopy
            movingNodes = []
            Task { await moveOrCopy(items, to: dest, name: name, copy: copy) }
        } onCancel: {
            showMove = false
            movingNodes = []
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if session.hasCookie {
            loggedIn
        } else {
            ContentUnavailableView {
                Label("115 未登录", systemImage: "externaldrive.badge.person.crop")
            } description: {
                Text("Cookie 需含 UID / CID / SEID。登录后可选文件夹上传相册和文件，锁屏后台也会继续。")
            } actions: {
                Button("登录 115") { showLogin = true }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var loggedIn: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .files: drivePane
        case .upload: uploadPane
        case .offline: Pan115OfflineView()
        case .backup: backupPane
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if session.hasCookie {
                PhotosPicker(selection: $photos, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle")
                }
                Button {
                    Pan115FilePicker.present { urls in
                        enqueueFiles(urls)
                    }
                } label: { Image(systemName: "folder.badge.plus") }
                Button {
                    editingBackup = nil
                    showBackupEditor = true
                } label: { Image(systemName: "plus.rectangle.on.folder") }
                Menu {
                    Button("新建文件夹") { showFolder = true }
                    Button("转存分享") { showShare = true }
                    Button("回收站") { showRecycle = true }
                    Button("离线下载") { tab = .offline }
                    Button("新建备份") {
                        editingBackup = nil
                        showBackupEditor = true
                    }
                    Button("暂停全部") { uploader.pauseAll() }
                    Button("继续全部") { uploader.resumeAll() }
                    Button("取消全部", role: .destructive) { uploader.cancelAll() }
                    Button("清除完成记录") { uploader.removeHistory() }
                    Button("重新登录") { showLogin = true }
                    Button("退出 115", role: .destructive) { session.clear() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                Button("登录") { showLogin = true }
            }
        }
    }

    private var uploadPane: some View {
        List {
            Section {
                Button { showUploadFolder = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上传到")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(session.uploadFolderName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Text("更改")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                Text("这里只影响手动上传相册/文件，和备份任务的目标互不影响。备份请在「备份」里单独选目录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            let active = uploader.activeJobs
            if !active.isEmpty {
                Section {
                    ForEach(active) { job in
                        jobRow(job, showControls: true)
                    }
                } header: {
                    HStack {
                        Text("正在上传 (\(active.count))")
                        Spacer()
                        Button("全部暂停") { uploader.pauseAll() }
                            .font(.caption)
                    }
                }
            }

            let failed = uploader.failedJobs
            if !failed.isEmpty {
                Section("失败 (\(failed.count))") {
                    ForEach(failed) { job in
                        jobRow(job, showControls: true)
                    }
                }
            }

            let history = uploader.historyJobs
            Section("上传完成 (\(history.count))") {
                if history.isEmpty {
                    Text("还没有完成记录").foregroundStyle(.secondary)
                } else {
                    ForEach(history) { job in
                        jobRow(job, showControls: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var drivePane: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索文件或文件夹", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchHits = []
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    if searching { ProgressView().controlSize(.small) }
                }
            }

            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("搜索结果") {
                    if searchHits.isEmpty, !searching {
                        Text("没有找到「\(searchText)」").foregroundStyle(.secondary)
                    }
                    ForEach(searchHits) { node in
                        Button {
                            openSearchHit(node)
                        } label: {
                            Label(node.name, systemImage: node.isDir ? "folder.fill" : "doc.fill")
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folderName).font(.subheadline)
                            if let space {
                                Text("已用 \(byteText(space.used)) / \(byteText(space.total))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if path.count > 1 {
                            Button("上级") { path.removeLast(); Task { await reload() } }
                        }
                    }
                    if loading { ProgressView() }
                    if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
                    ForEach(folders) { node in
                        Button {
                            path.append((node.id, node.name))
                            Task { await reload() }
                        } label: {
                            Label(node.name, systemImage: "folder.fill")
                        }
                        .contextMenu { nodeActions(node) }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await deleteNode(node) } }
                        }
                    }
                    ForEach(files) { node in
                        Button {
                            openFile(node)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(node.name).lineLimit(1)
                                    Text(playHint(node)).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: fileIcon(node.name))
                            }
                        }
                        .disabled(playBusy)
                        .contextMenu { nodeActions(node) }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await deleteNode(node) } }
                        }
                    }
                }
            }
        }
        .refreshable { await reload() }
    }

    private var backupPane: some View {
        List {
            Section {
                Button {
                    editingBackup = nil
                    showBackupEditor = true
                } label: {
                    Label("新建备份", systemImage: "plus.circle.fill")
                }
            }
            if backups.tasks.isEmpty {
                Section {
                    Text("选择本地文件夹，备份到 115 指定目录。可监控更改、定时扫描、筛选文件。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(0..<backups.tasks.count, id: \.self) { index in
                        Pan115BackupTaskRow(
                            task: backups.tasks[index],
                            scanning: backups.scanningIDs.contains(backups.tasks[index].id),
                            progress: backups.progress[backups.tasks[index].id],
                            onToggle: { backups.setEnabled(backups.tasks[index].id, $0) },
                            onScan: { backups.scanNow(backups.tasks[index].id) },
                            onEdit: {
                                editingBackup = backups.tasks[index]
                                showBackupEditor = true
                            },
                            onDelete: { backups.delete(backups.tasks[index].id) }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func jobRow(_ job: Pan115Uploader.Job, showControls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: icon(for: job))
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 36, height: 36)
                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(detailLine(job)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if job.status == .uploading || job.status == .hashing {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 3)
                        Circle().trim(from: 0, to: job.progress)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(job.progress * 100))%")
                            .font(.caption2.monospacedDigit())
                    }
                    .frame(width: 44, height: 44)
                }
            }
            if showControls && (job.status == .uploading || job.status == .waiting || job.status == .hashing || job.status == .paused || job.status == .failed) {
                if job.status == .uploading || job.status == .waiting || job.status == .hashing {
                    ProgressView(value: job.progress)
                }
                HStack {
                    if job.status == .uploading || job.status == .waiting || job.status == .hashing {
                        Button("暂停") { uploader.pause(job.id) }
                    }
                    if job.status == .paused || job.status == .failed {
                        Button("继续") { uploader.resume(job.id) }
                    }
                    Button("取消", role: .destructive) { uploader.cancel(job.id) }
                    Spacer()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for job: Pan115Uploader.Job) -> String {
        let n = job.name.lowercased()
        if n.hasSuffix(".mp4") || n.hasSuffix(".mov") || n.hasSuffix(".m4v") { return "film" }
        if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") || n.hasSuffix(".png") || n.hasSuffix(".heic") { return "photo" }
        return "doc"
    }

    private func detailLine(_ job: Pan115Uploader.Job) -> String {
        switch job.status {
        case .uploading:
            return "\(byteText(job.size))  \(speedText(job.speedBps))  → \(job.folderName)"
        case .waiting:
            return "排队 · \(byteText(job.size))  → \(job.folderName)"
        case .hashing:
            return "计算 SHA1 · \(byteText(job.size))"
        case .paused:
            return "已暂停 · \(byteText(job.size))"
        case .failed:
            return job.message
        case .cancelled:
            return "已取消"
        case .done:
            return "\(dateText(job.finishedAt ?? job.createdAt))  ·  \(byteText(job.size))"
        }
    }

    private func speedText(_ bps: Double) -> String {
        if bps < 1 { return "0 B/s" }
        if bps >= 1_073_741_824 { return String(format: "%.1f GB/s", bps / 1_073_741_824) }
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.0f B/s", bps)
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return f.string(from: date)
    }

    private func reload() async {
        guard session.hasCookie else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            nodes = try await Pan115API.listAll(cid: cid)
            if let info = try? await Pan115API.spaceInfo() {
                space = info
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func makeFolder(_ name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        do {
            _ = try await Pan115API.mkdir(parent: cid, name: n)
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @ViewBuilder
    private func nodeActions(_ node: Pan115API.Node) -> some View {
        Button("重命名") {
            renameTarget = node
            renameText = node.name
            showRename = true
        }
        Button("移动到…") {
            movingNodes = [node]
            moveIsCopy = false
            showMove = true
        }
        Button("复制到…") {
            movingNodes = [node]
            moveIsCopy = true
            showMove = true
        }
        Button("删除", role: .destructive) {
            Task { await deleteNode(node) }
        }
    }

    private func rename(_ node: Pan115API.Node?, _ name: String) async {
        guard let node else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != node.name else { return }
        do {
            try await Pan115API.rename(id: node.id, name: n)
            await reload()
        } catch {
            pickNotice = error.localizedDescription
        }
    }

    private func deleteNode(_ node: Pan115API.Node) async {
        do {
            try await Pan115API.delete(id: node.id, pid: cid)
            await reload()
        } catch {
            pickNotice = error.localizedDescription
        }
    }

    private func moveOrCopy(_ items: [Pan115API.Node], to dest: String, name: String, copy: Bool) async {
        let ids = items.map(\.id)
        do {
            if copy {
                try await Pan115API.copy(ids: ids, to: dest)
            } else {
                try await Pan115API.move(ids: ids, to: dest)
            }
            pickNotice = (copy ? "已复制到 " : "已移动到 ") + name
            await reload()
        } catch {
            pickNotice = error.localizedDescription
        }
    }

    private func enqueueFiles(_ urls: [URL]) {
        let items = Pan115Inbox.ingest(urls)
        guard !items.isEmpty else {
            pickNotice = "没有读到可上传的文件，请再试一次「打开」"
            return
        }
        for item in items {
            uploader.enqueue(fileURL: item.url, name: item.name, size: item.size, cid: session.uploadCID, folderName: session.uploadFolderName, ownsFile: true)
        }
        tab = .upload
        pickNotice = "已加入 \(items.count) 个文件，上传到 \(session.uploadFolderName)"
    }

    private func runSearch(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else {
            searchHits = []
            searching = false
            return
        }
        searching = true
        defer { searching = false }
        do {
            let hits = try await Pan115API.search(keyword: q, cid: "0", foldersOnly: false)
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines) == q {
                searchHits = hits
            }
        } catch {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines) == q {
                errorText = error.localizedDescription
                searchHits = []
            }
        }
    }

    private func openSearchHit(_ node: Pan115API.Node) {
        searchText = ""
        searchHits = []
        if node.isDir {
            path = [("0", "根目录"), (node.id, node.name)]
            tab = .files
            Task { await reload() }
        } else {
            openFile(node)
        }
    }

    private func fileIcon(_ name: String) -> String {
        if Pan115API.isPlayable(name) { return "play.circle.fill" }
        if Pan115API.isImage(name) { return "photo.fill" }
        return "doc.fill"
    }

    private func playHint(_ node: Pan115API.Node) -> String {
        if Pan115API.isPlayable(node.name) {
            return "点按播放 · \(byteText(node.size))"
        }
        if Pan115API.isImage(node.name) {
            return "点按查看 · \(byteText(node.size))"
        }
        return byteText(node.size)
    }

    private func openFile(_ node: Pan115API.Node) {
        guard !node.pickCode.isEmpty else {
            pickNotice = "缺少 pickcode，无法打开"
            return
        }
        if Pan115API.isImage(node.name) {
            playBusy = true
            Task {
                defer { playBusy = false }
                do {
                    let url = try await Pan115API.downloadURL(pickCode: node.pickCode)
                    AppState.shared.open115Image(url: url, title: node.name)
                } catch {
                    pickNotice = error.localizedDescription
                }
            }
            return
        }
        guard Pan115API.isPlayable(node.name) else {
            pickNotice = "这个文件不能直接打开"
            return
        }
        playBusy = true
        Task {
            defer { playBusy = false }
            do {
                let src = try await Pan115API.playSource(pickCode: node.pickCode, filename: node.name)
                AppState.shared.open115(url: src.url, title: node.name, ffmpeg: src.ffmpeg)
            } catch {
                pickNotice = error.localizedDescription
            }
        }
    }

    private func enqueuePhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) ? "mov" : "jpg"
            let name = suggestedPhotoName(item, ext: ext)
            let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("115Inbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let file = dest.appendingPathComponent(name)
            try? data.write(to: file)
            uploader.enqueue(fileURL: file, name: name, size: Int64(data.count), cid: session.uploadCID, folderName: session.uploadFolderName, ownsFile: true)
        }
    }

    private func suggestedPhotoName(_ item: PhotosPickerItem, ext: String) -> String {
        if let id = item.itemIdentifier, !id.isEmpty {
            return "IMG_\(id.prefix(12)).\(ext)"
        }
        return "IMG_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6)).\(ext)"
    }

    private func byteText(_ n: Int64) -> String {
        if n >= 1_073_741_824 { return String(format: "%.2f GB", Double(n) / 1_073_741_824) }
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }
}

private struct Pan115BackupTaskRow: View {
    let task: Pan115BackupTask
    let scanning: Bool
    let progress: Pan115BackupStore.ScanProgress?
    let onToggle: (Bool) -> Void
    let onScan: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name).font(.headline)
                    Text(task.sourceName.isEmpty ? "未选择源文件夹" : task.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(destText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { task.enabled }, set: onToggle))
                    .labelsHidden()
            }
            if scanning, let p = progress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView()
                        Text(p.total > 0 ? "\(p.index)/\(p.total)  \(Int(p.fraction * 100))%" : p.phase)
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Spacer()
                        Text("上传 \(p.queued) · 跳过 \(p.skipped)")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                    if p.total > 0 {
                        ProgressView(value: p.fraction)
                    }
                    if !p.current.isEmpty {
                        Text(p.current)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                    }
                }
            } else if let msg = task.lastMessage {
                Text(msg).font(.caption).foregroundStyle(task.lastError == nil ? Color.secondary : Color.red)
            }
            HStack {
                Button("立即扫描", action: onScan)
                Button("编辑", action: onEdit)
                Spacer()
                Button("删除", role: .destructive, action: onDelete)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var destText: String {
        let names = task.destinations.filter { $0.enabled }.map(\.name).joined(separator: "、")
        return names.isEmpty ? "未配置目标" : names
    }
}
