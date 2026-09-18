import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct Pan115View: View {
    @ObservedObject private var session = Pan115Session.shared
    @ObservedObject private var uploader = Pan115Uploader.shared
    @State private var nodes: [Pan115API.Node] = []
    @State private var path: [(id: String, name: String)] = [("0", "根目录")]
    @State private var loading = false
    @State private var errorText: String?
    @State private var showLogin = false
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var newFolder = ""
    @State private var showFolder = false
    @State private var pickingPhotos = false

    private var cid: String { path.last?.id ?? "0" }
    private var folders: [Pan115API.Node] { nodes.filter(\.isDir) }
    private var files: [Pan115API.Node] { nodes.filter { !$0.isDir } }

    var body: some View {
        NavigationStack {
            Group {
                if !session.hasCookie {
                    ContentUnavailableView {
                        Label("115 未登录", systemImage: "externaldrive.badge.person.crop")
                    } description: {
                        Text("对照 OpenList：Cookie 含 UID / CID / SEID。登录后可浏览目录、上传相册和文件，支持暂停与取消。")
                    } actions: {
                        Button("登录 115") { showLogin = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section("当前目录") {
                            HStack {
                                Text(path.map(\.name).joined(separator: " / "))
                                    .font(.subheadline)
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
                            }
                            ForEach(files) { node in
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(node.name).lineLimit(1)
                                        Text(byteText(node.size)).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "doc.fill")
                                }
                            }
                        }

                        Section("上传队列 \(uploader.jobs.count)") {
                            if uploader.jobs.isEmpty {
                                Text("从相册或文件加入上传").foregroundStyle(.secondary)
                            } else {
                                ForEach(uploader.jobs) { job in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(job.name).lineLimit(1)
                                            Spacer()
                                            Text(job.status.rawValue == "done" ? "完成" : statusText(job))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        ProgressView(value: job.progress)
                                        Text(job.message).font(.caption2).foregroundStyle(.secondary)
                                        HStack {
                                            if job.status == .uploading || job.status == .waiting || job.status == .hashing {
                                                Button("暂停") { uploader.pause(job.id) }
                                            }
                                            if job.status == .paused {
                                                Button("继续") { uploader.resume(job.id) }
                                            }
                                            if job.status != .done && job.status != .cancelled {
                                                Button("取消", role: .destructive) { uploader.cancel(job.id) }
                                            }
                                        }
                                        .font(.caption)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .refreshable { await reload() }
                }
            }
            .navigationTitle("115")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if session.hasCookie {
                        PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                            Image(systemName: "photo.on.rectangle")
                        }
                        Button { showFiles = true } label: { Image(systemName: "folder.badge.plus") }
                        Menu {
                            Button("新建文件夹") { showFolder = true }
                            Button("设为上传目录") { session.setTargetCID(cid) }
                            Button("暂停全部") { uploader.pauseAll() }
                            Button("继续全部") { uploader.resumeAll() }
                            Button("取消全部", role: .destructive) { uploader.cancelAll() }
                            Button("清除已完成") { uploader.removeFinished() }
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
            .sheet(isPresented: $showLogin) { Pan115LoginView() }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { enqueueFiles(urls) }
            }
            .onChange(of: photos) { _, items in
                Task { await enqueuePhotos(items); photos = [] }
            }
            .alert("新建文件夹", isPresented: $showFolder) {
                TextField("名称", text: $newFolder)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let name = newFolder
                    newFolder = ""
                    Task { await makeFolder(name) }
                }
            }
            .task {
                if session.hasCookie { await reload() }
            }
            .onChange(of: session.hasCookie) { _, ok in
                if ok {
                    Task { await reload() }
                } else {
                    nodes = []
                }
            }
        }
    }

    private func reload() async {
        guard session.hasCookie else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            nodes = try await Pan115API.list(cid: cid)
            session.setTargetCID(cid)
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

    private func enqueueFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = copyToInbox(url)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            uploader.enqueue(fileURL: dest, name: dest.lastPathComponent, size: size, cid: cid)
        }
    }

    private func enqueuePhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) ? "mov" : "jpg"
            let name = "IMG_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6)).\(ext)"
            let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("115Inbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let file = dest.appendingPathComponent(name)
            try? data.write(to: file)
            uploader.enqueue(fileURL: file, name: name, size: Int64(data.count), cid: cid)
        }
    }

    private func copyToInbox(_ url: URL) -> URL {
        let destDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("115Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : url
    }

    private func statusText(_ job: Pan115Uploader.Job) -> String {
        switch job.status {
        case .waiting: return "排队"
        case .hashing: return "校验"
        case .uploading: return String(format: "%.0f%%", job.progress * 100)
        case .paused: return "暂停"
        case .done: return "完成"
        case .failed: return "失败"
        case .cancelled: return "取消"
        }
    }

    private func byteText(_ n: Int64) -> String {
        if n >= 1_073_741_824 { return String(format: "%.2f GB", Double(n) / 1_073_741_824) }
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }
}
