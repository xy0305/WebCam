import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recs = RecordingManager.shared
    @ObservedObject private var monitor = AutoRecordMonitor.shared
    @State private var files: [URL] = []
    @State private var exportBanner: String?
    @State private var showAdd = false
    @State private var newUsername = ""

    private var liveSessions: [RecordingSession] {
        recs.sessions.values.sorted { $0.username < $1.username }
    }

    var body: some View {
        NavigationStack {
            List {
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

                Section {
                    if monitor.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 34))
                                .foregroundStyle(.red)
                            Text("添加想自动录制的主播")
                                .font(.headline)
                            Text("打开 App 后自动检测，在线时开始录制")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
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
                    Button { newUsername = ""; showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("添加自动录制主播", isPresented: $showAdd) {
                TextField("主播用户名", text: $newUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("添加") { _ = monitor.add(newUsername) }
            } message: {
                Text("在线时会自动开始录制最高画质和声音。")
            }
            .alert("导出", isPresented: Binding(
                get: { exportBanner != nil }, set: { if !$0 { exportBanner = nil } }
            )) {
                Button("好", role: .cancel) { exportBanner = nil }
            } message: { Text(exportBanner ?? "") }
            .onAppear { files = RecordingStore.list(); monitor.startMonitoring() }
            .onChange(of: recs.activeUsernames.count) { _, _ in files = RecordingStore.list() }
            .onChange(of: recs.banner) { _, _ in files = RecordingStore.list() }
            .onChange(of: recs.libraryRevision) { _, _ in files = RecordingStore.list() }
        }
    }

    private func exportToAlbum(_ url: URL) {
        PhotoLibraryExporter.hapticStart()
        Task {
            do {
                try await PhotoLibraryExporter.saveVideo(url)
                PhotoLibraryExporter.hapticSuccess()
                await MainActor.run { exportBanner = "已保存到相册" }
            } catch {
                PhotoLibraryExporter.hapticError()
                await MainActor.run { exportBanner = error.localizedDescription }
            }
        }
    }
}

private struct LiveRecordingRow: View {
    @ObservedObject var session: RecordingSession
    var onOpen: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(.red.opacity(0.13)).frame(width: 42, height: 42)
                        Circle().fill(.red).frame(width: 10, height: 10)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.username).font(.headline).foregroundStyle(.primary)
                        Text("\(session.phaseText) · \(session.elapsedText) · \(session.bytesText)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(session.isRunning ? "停止" : "封装中", action: onStop)
                .buttonStyle(.borderedProminent)
                .tint(session.isRunning ? .red : .gray)
                .disabled(!session.isRunning)
        }
        .padding(.vertical, 4)
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
        if isRecording { return .red }
        switch state {
        case .online: return .green
        case .checking: return .orange
        case .offline: return .gray
        case .failed: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                AsyncImage(url: URL(string: "https://thumb.live.mmcdn.com/ri/\(entry.username).jpg")) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { Color.secondary.opacity(0.12).overlay(Image(systemName: "person.fill").foregroundStyle(.secondary)) }
                }
                .frame(width: 50, height: 50).clipShape(Circle())
            }.buttonStyle(.plain)

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
                .labelsHidden().tint(.red)

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
