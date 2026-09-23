import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recs = RecordingManager.shared
    @ObservedObject private var monitor = AutoRecordMonitor.shared
    @State private var files: [URL] = []
    @State private var exportBanner: String?
    @State private var showAdd = false
    @State private var newUsername = ""
    @State private var showStopAllConfirm = false
    @State private var showExportAllConfirm = false
    @State private var showDeleteAllConfirm = false
    @State private var isExportingAll = false
    @State private var isExportingOne = false
    @State private var exportProgress = ""
    @State private var librarySizeText = ""
    @State private var hiddenSizeText = ""
    @State private var cacheSizeText = ""

    private var liveSessions: [RecordingSession] {
        recs.sessions.values.sorted { $0.username < $1.username }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section("存储占用") {
            LabeledContent("录像与分片", value: librarySizeText)
            LabeledContent("其中隐藏缓存", value: hiddenSizeText)
            LabeledContent("网页/网络缓存", value: cacheSizeText)
            Button {
                Haptics.tap()
                let message = RecordingStore.sweepHiddenCaches(
                    excludingActiveUsernames: recs.activeUsernames,
                    excludingStems: recs.activeFileStems
                )
                refreshStorageStats()
                ToastCenter.shared.show(message)
            } label: {
                Label("清理隐藏缓存", systemImage: "sparkles")
            }
            Text("隐藏缓存包括中断录制的分片、封装失败残留和过期临时文件。列表里的录像要手动删除或「清空全部」。")
                .font(.footnote)
                .foregroundStyle(AppTheme.inkSecondary)
        }
    }

    private func refreshStorageStats() {
        librarySizeText = RecordingStore.formatBytes(RecordingStore.libraryBytes())
        hiddenSizeText = RecordingStore.formatBytes(
            RecordingStore.hiddenBytes(
                excludingActiveUsernames: recs.activeUsernames,
                excludingStems: recs.activeFileStems
            )
        )
        cacheSizeText = RecordingStore.formatBytes(RecordingStore.cacheBytes())
    }

    @ViewBuilder
    private var activeRecordingSection: some View {
        if !liveSessions.isEmpty {
            Section("正在录制 \(liveSessions.count) 路") {
                ForEach(liveSessions) { session in
                    LiveRecordingRow(session: session) {
                        appState.openPlayer(username: session.username)
                    } onStop: {
                        if monitor.entries.contains(where: { $0.username == session.username }) {
                            monitor.manualStop(session.username)
                        } else {
                            recs.stop(session.username)
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                activeRecordingSection
                storageSection

                Section {
                    if monitor.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 34))
                                .foregroundStyle(AppTheme.accent)
                            Text("添加想自动录制的主播")
                                .font(.headline)
                            Text("打开 App 后自动检测，在线时开始录制")
                                .font(.caption)
                                .foregroundStyle(AppTheme.inkSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(monitor.entries) { entry in
                            AutoRecordRow(
                                entry: entry,
                                state: monitor.state(for: entry.username),
                                isRecording: recs.isRecording(entry.username),
                                onOpen: { appState.openPlayer(username: entry.username) },
                                onToggleAuto: { monitor.setAuto($0, for: entry.username) },
                                onRecord: {
                                    if recs.isRecording(entry.username) {
                                        monitor.manualStop(entry.username)
                                    } else {
                                        monitor.manualStart(entry.username)
                                    }
                                }
                            )
                            .swipeActions {
                                Button(role: .destructive) { monitor.remove(entry.username) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("自动录制")
                        Spacer()
                        if monitor.isChecking { ProgressView().controlSize(.small) }
                    }
                } footer: {
                    Text("启用自动录制后，每分钟检测一次。主播在线且处于公开状态时自动开始。")
                }

                Section("录像文件") {
                    if files.isEmpty {
                        Text("没有录像，录制完成后会显示在这里")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files, id: \.path) { url in
                            Button { appState.openRecording(url) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "film.fill")
                                        .foregroundStyle(.blue)
                                        .frame(width: 32, height: 32)
                                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(RecordingStore.displayName(url))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(RecordingStore.sizeText(url))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    RecordingStore.delete(url); files = RecordingStore.list()
                                } label: { Label("删除", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { exportToAlbum(url) } label: {
                                    Label("相册", systemImage: "photo.on.rectangle.angled")
                                }.tint(.blue)
                            }
                            .contextMenu {
                                Button { exportToAlbum(url) } label: {
                                    Label("导出到相册", systemImage: "square.and.arrow.down")
                                }
                                ShareLink(item: RecordingStore.shareURL(for: url)) { Label("分享", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) {
                                    RecordingStore.delete(url); files = RecordingStore.list()
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("录像")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await monitor.checkAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.disabled(monitor.isChecking || monitor.entries.isEmpty)
                    Menu {
                        Button {
                            showStopAllConfirm = true
                        } label: {
                            Label("全部中断", systemImage: "stop.circle")
                        }
                        .disabled(liveSessions.isEmpty)

                        Button {
                            showExportAllConfirm = true
                        } label: {
                            Label("全部导出到相册", systemImage: "photo.on.rectangle.angled")
                        }
                        .disabled(files.isEmpty || isExportingAll)

                        Button(role: .destructive) {
                            showDeleteAllConfirm = true
                        } label: {
                            Label("删除全部录像", systemImage: "trash")
                        }
                        .disabled(files.isEmpty || isExportingAll)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    Button { newUsername = ""; showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .confirmationDialog("确定中断全部录制？", isPresented: $showStopAllConfirm, titleVisibility: .visible) {
                Button("全部中断并关闭自动录制", role: .destructive) {
                    stopAllRecordings()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前录制会停止并封装；相关主播不会在下一轮检测时自动重启。")
            }
            .confirmationDialog("导出全部录像到相册？", isPresented: $showExportAllConfirm, titleVisibility: .visible) {
                Button("开始导出") { exportAllToAlbum() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("恢复录像会先无损封装为 MP4，再保存到相册并删除 App 内分片。")
            }
            .confirmationDialog("确定删除全部录像？", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
                Button("删除全部录像", role: .destructive) {
                    deleteAllRecordings()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将永久删除 \(files.count) 个已保存录像，无法恢复；不会影响当前正在录制的内容。")
            }
            .alert("添加自动录制主播", isPresented: $showAdd) {
                TextField("主播用户名或 Chaturbate 链接", text: $newUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("添加") { _ = monitor.add(newUsername) }
            } message: {
                Text("可粘贴用户名、英文站或中文站房间链接；在线时会自动开始录制最高画质和声音。")
            }
            .overlay {
                if isExportingAll || isExportingOne {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(exportProgress).font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(radius: 12)
                }
            }
            .alert("导出", isPresented: Binding(
                get: { exportBanner != nil }, set: { if !$0 { exportBanner = nil } }
            )) {
                Button("好", role: .cancel) { exportBanner = nil }
            } message: { Text(exportBanner ?? "") }
            .onAppear {
                RecordingManager.shared.recoverOrphans()
                files = RecordingStore.list()
                refreshStorageStats()
                monitor.startMonitoring()
            }
            .onChange(of: recs.activeUsernames.count) { _, _ in
                files = RecordingStore.list()
                refreshStorageStats()
            }
            .onChange(of: recs.banner) { _, _ in
                files = RecordingStore.list()
                refreshStorageStats()
            }
            .onChange(of: recs.libraryRevision) { _, _ in
                files = RecordingStore.list()
                refreshStorageStats()
            }
        }
    }

    private func deleteAllRecordings() {
        let count = files.count
        // 清掉录像列表以外的 .part 分片和封装残留，否则它们会继续占用 App 存储。
        RecordingStore.clearAll(excludingActiveUsernames: recs.activeUsernames, excludingStems: recs.activeFileStems)
        files = RecordingStore.list()
        recs.noteLibraryChanged()
        exportBanner = "已删除全部录像与缓存（共 \(count) 个）"
    }

    private func stopAllRecordings() {
        let names = recs.activeUsernames
        names.forEach { username in
            if monitor.entries.contains(where: { $0.username == username }) {
                monitor.manualStop(username)
            } else {
                recs.stop(username)
            }
        }
        exportBanner = names.isEmpty ? "当前没有正在录制的主播" : "已中断全部录制（共 \(names.count) 路）"
    }

    private func exportAllToAlbum() {
        let candidates = files.filter {
            ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) ||
            $0.lastPathComponent.lowercased() == "index.m3u8"
        }
        guard !candidates.isEmpty else {
            exportBanner = "没有可导出的录像文件"
            return
        }
        isExportingAll = true
        exportProgress = "准备导出 0/\(candidates.count)"
        PhotoLibraryExporter.hapticStart()
        Task {
            var success = 0
            var failed = 0
            for (index, url) in candidates.enumerated() {
                await MainActor.run { exportProgress = "正在导出 \(index + 1)/\(candidates.count)" }
                do {
                    let prepared = try await RecordingStore.prepareForAlbumExport(url)
                    try await PhotoLibraryExporter.saveVideo(prepared.file)
                    // 相册导入确认后仍保留 App 原件，避免 Photos 索引/同步延迟时误删唯一副本。
                    // 用户在确认相册里可见后可手动删除，或用“删除全部录像”释放空间。
                    if prepared.cleanup { try? FileManager.default.removeItem(at: prepared.file) }
                    success += 1
                } catch {
                    failed += 1
                }
            }
            await MainActor.run {
                isExportingAll = false
                exportProgress = ""
                // 所有成功导出的 App 副本都已删除，同时清理旧分片/封装残留。
                RecordingStore.purgeTemporary(excludingActiveUsernames: recs.activeUsernames, excludingStems: recs.activeFileStems)
                files = RecordingStore.list()
                recs.noteLibraryChanged()
                if failed == 0 {
                    PhotoLibraryExporter.hapticSuccess()
                    exportBanner = "已全部导出到相册（共 \(success) 个）"
                } else {
                    PhotoLibraryExporter.hapticError()
                    exportBanner = "导出完成：成功 \(success) 个，失败 \(failed) 个"
                }
            }
        }
    }

    private func exportToAlbum(_ url: URL) {
        guard !isExportingOne && !isExportingAll else { return }
        isExportingOne = true
        exportProgress = url.lastPathComponent.lowercased() == "index.m3u8" ? "正在封装恢复录像…" : "正在准备录像…"
        PhotoLibraryExporter.hapticStart()
        Task {
            do {
                let prepared = try await RecordingStore.prepareForAlbumExport(url)
                await MainActor.run { exportProgress = "正在生成相册兼容视频…" }
                await MainActor.run { exportProgress = "正在保存到相册…" }
                try await PhotoLibraryExporter.saveVideo(prepared.file)
                // 相册导入完成后保留 App 原件；确认相册可见后再手动删除，绝不冒险删唯一副本。
                if prepared.cleanup { try? FileManager.default.removeItem(at: prepared.file) }
                PhotoLibraryExporter.hapticSuccess()
                await MainActor.run {
                    isExportingOne = false
                    exportProgress = ""
                    files = RecordingStore.list()
                    recs.noteLibraryChanged()
                    exportBanner = "已提交到相册，App 本地原件已保留，请确认后手动删除"
                }
            } catch {
                PhotoLibraryExporter.hapticError()
                await MainActor.run {
                    isExportingOne = false
                    exportProgress = ""
                    exportBanner = error.localizedDescription
                }
            }
        }
    }
}

private struct LiveRecordingRow: View {
    @ObservedObject var session: RecordingSession
    var onOpen: () -> Void
    var onStop: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                onOpen()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(AppTheme.live.opacity(0.18)).frame(width: 42, height: 42)
                        Circle().fill(AppTheme.live).frame(width: 10, height: 10)
                            .scaleEffect(pulse ? 1.25 : 1)
                            .shadow(color: AppTheme.live.opacity(0.6), radius: pulse ? 5 : 2)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.username).font(.headline).foregroundStyle(AppTheme.ink)
                        Text("\(session.phaseText) · \(session.elapsedText) · \(session.bytesText)")
                            .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.inkSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.inkSecondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())

            Button {
                Haptics.warning()
                onStop()
            } label: {
                Text(session.isRunning ? "停止" : "保留并结束")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.live.opacity(0.85), in: Capsule())
            }
            .buttonStyle(SoftPress())
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct AutoRecordRow: View {
    let entry: AutoRecordMonitor.Entry
    let state: AutoRecordMonitor.State
    let isRecording: Bool
    var onOpen: () -> Void
    var onToggleAuto: (Bool) -> Void
    var onRecord: () -> Void

    private var color: Color {
        if isRecording { return AppTheme.live }
        switch state {
        case .online: return AppTheme.success
        case .checking: return AppTheme.favorite
        case .offline: return AppTheme.inkSecondary
        case .failed: return AppTheme.favorite
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: "https://thumb.live.mmcdn.com/ri/\(entry.username).jpg")) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                        else { Color.secondary.opacity(0.12).overlay(Image(systemName: "person.fill").foregroundStyle(AppTheme.inkSecondary)) }
                    }
                    .frame(width: 50, height: 50).clipShape(Circle())
                    .overlay { Circle().stroke(Color(hex: 0xE8F0F8).opacity(0.2), lineWidth: 1) }
                }
            }.buttonStyle(SoftPress())

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.username).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(isRecording ? "正在录制" : state.title)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            Toggle("", isOn: Binding(get: { entry.autoRecord }, set: onToggleAuto))
                .labelsHidden().tint(AppTheme.accent)

            Button(action: onRecord) {
                Image(systemName: isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isRecording ? .white : .red)
                    .frame(width: 38, height: 38)
                    .background(isRecording ? Color.red : Color.red.opacity(0.1), in: Circle())
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 5)
    }
}
