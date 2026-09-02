import KSPlayer
import SwiftUI

struct RecordingsView: View {
    @ObservedObject private var recs = RecordingManager.shared
    @State private var files: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                if !recs.activeUsernames.isEmpty {
                    Section("正在录制 \(recs.activeUsernames.count) 路") {
                        ForEach(recs.activeUsernames, id: \.self) { name in
                            HStack {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).font(.subheadline.weight(.semibold))
                                    Text("\(recs.session(for: name)?.elapsedText ?? "")  \(recs.session(for: name)?.bytesText ?? "")")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("停止") { recs.stop(name) }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.red)
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
                            NavigationLink {
                                KSVideoPlayerView(url: url, options: KSOptions(), title: url.lastPathComponent)
                                    .ignoresSafeArea(edges: .bottom)
                                    .navigationTitle(url.lastPathComponent)
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.lastPathComponent).font(.subheadline.weight(.semibold))
                                    Text(RecordingStore.sizeText(url)).font(.caption).foregroundStyle(.secondary)
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
        }
    }
}
