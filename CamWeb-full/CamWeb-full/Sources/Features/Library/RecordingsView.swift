import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recs = RecordingManager.shared
    @State private var files: [URL] = []
    @State private var exportBanner: String?

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
                                recs.stop(session.username)
                            }
                        }
                    }
                }

                Section {
                    if files.isEmpty {
                        Text("没有录像，播放时点录制会保存到这里")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files, id: \.path) { url in
                            Button {
                                appState.openRecording(url)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(RecordingStore.displayName(url))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(RecordingStore.sizeText(url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    RecordingStore.delete(url)
                                    files = RecordingStore.list()
                                } label: { Label("删除", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    exportToAlbum(url)
                                } label: {
                                    Label("相册", systemImage: "photo.on.rectangle.angled")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    exportToAlbum(url)
                                } label: {
                                    Label("导出到相册", systemImage: "square.and.arrow.down")
                                }
                                ShareLink(item: url) {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    RecordingStore.delete(url)
                                    files = RecordingStore.list()
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("录像")
                }
            }
            .navigationTitle("录像")
            .alert("导出", isPresented: Binding(
                get: { exportBanner != nil },
                set: { if !$0 { exportBanner = nil } }
            )) {
                Button("好", role: .cancel) { exportBanner = nil }
            } message: {
                Text(exportBanner ?? "")
            }
            .onAppear { files = RecordingStore.list() }
            .onChange(of: recs.activeUsernames.count) { _, _ in
                files = RecordingStore.list()
            }
            .onChange(of: recs.banner) { _, _ in
                files = RecordingStore.list()
            }
            .onChange(of: recs.libraryRevision) { _, _ in
                files = RecordingStore.list()
            }
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
    var onStop: () -> Void

    var body: some View {
        HStack {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.username).font(.subheadline.weight(.semibold))
                Text("\(session.phaseText) · \(session.elapsedText)  \(session.bytesText)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(session.isRunning ? "停止" : "封装中", action: onStop)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.isRunning ? .red : .secondary)
                .disabled(!session.isRunning)
        }
    }
}
