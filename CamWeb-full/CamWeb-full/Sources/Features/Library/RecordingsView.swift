import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recs = RecordingManager.shared
    @State private var files: [URL] = []

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
                                    Text(url.lastPathComponent)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(RecordingStore.sizeText(url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    RecordingStore.delete(url)
                                    files = RecordingStore.list()
                                } label: { Label("删除", systemImage: "trash") }
                                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                            }
                        }
                    }
                } header: {
                    Text("录像")
                }
            }
            .navigationTitle("录像")
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
}

private struct LiveRecordingRow: View {
    @ObservedObject var session: RecordingSession
    var onStop: () -> Void

    var body: some View {
        HStack {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.username).font(.subheadline.weight(.semibold))
                Text("\(session.elapsedText)  \(session.bytesText)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("停止", action: onStop)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
}
