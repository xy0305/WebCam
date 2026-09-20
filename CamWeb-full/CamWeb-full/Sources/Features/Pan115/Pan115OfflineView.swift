import SwiftUI

/// 对照 OpenList OfflineList / OfflineDownload / DeleteOfflineTasks。
struct Pan115OfflineView: View {
    @ObservedObject private var session = Pan115Session.shared
    @State private var tasks: [Pan115API.OfflineTask] = []
    @State private var quota: Int64 = 0
    @State private var loading = false
    @State private var errorText: String?
    @State private var links = ""
    @State private var adding = false
    @State private var notice: String?
    @State private var showFolder = false
    @State private var destCID = "/"
    @State private var destName = "根目录"
    @State private var space: Pan115API.SpaceInfo?

    var body: some View {
        List {
            Section {
                if let space {
                    Text("空间 \(byteText(space.used)) / \(byteText(space.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button { showFolder = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("保存到").font(.caption).foregroundStyle(.secondary)
                            Text(destName).foregroundStyle(.primary)
                        }
                        Spacer()
                        Text("更改").font(.caption).foregroundStyle(.blue)
                    }
                }
                TextField("磁力 / ed2k / http，一行一条", text: $links, axis: .vertical)
                    .lineLimit(3...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await add() }
                } label: {
                    if adding { ProgressView() } else { Text("添加离线任务") }
                }
                .disabled(adding || links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("离线任务提交到 OpenList（工具 115）。目标：\(destName)")
            }

            Section {
                if loading && tasks.isEmpty { ProgressView() }
                if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
                if tasks.isEmpty, !loading {
                    Text("没有离线任务").foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.name.isEmpty ? task.url : task.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        HStack {
                            Text(task.statusText)
                            if task.status == 1 {
                                Text(String(format: "%.0f%%", task.percent))
                            }
                            Spacer()
                            Text(byteText(task.size)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(task.status == -1 ? .red : .secondary)
                    }
                    .swipeActions {
                        Button("删除任务", role: .destructive) {
                            Task { await delete([task], files: false) }
                        }
                        Button("连文件删") {
                            Task { await delete([task], files: true) }
                        }
                        .tint(.orange)
                    }
                }
            } header: {
                HStack {
                    Text("任务 (\(tasks.count))")
                    Spacer()
                    Button("刷新") { Task { await reload() } }.font(.caption)
                }
            }
        }
        .refreshable { await reload() }
        .task {
            destCID = session.targetCID
            await reload()
        }
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(isPresented: $showFolder) {
            Pan115FolderPicker { cid, name in
                destCID = cid
                destName = name
                session.setTargetCID(cid)
                showFolder = false
            } onCancel: {
                showFolder = false
            }
        }
    }

    private func reload() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let result = try await Pan115API.listOffline()
            tasks = result.tasks
            quota = result.quota
            space = try? await Pan115API.spaceInfo()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func add() async {
        let urls = links
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return }
        adding = true
        defer { adding = false }
        do {
            notice = try await Pan115API.addOffline(urls: urls, dirID: destCID)
            links = ""
            await reload()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func delete(_ items: [Pan115API.OfflineTask], files: Bool) async {
        do {
            try await Pan115API.deleteOffline(hashes: items.map(\.infoHash), deleteFiles: files)
            await reload()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func byteText(_ n: Int64) -> String {
        if n >= 1_073_741_824 { return String(format: "%.2f GB", Double(n) / 1_073_741_824) }
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }
}
