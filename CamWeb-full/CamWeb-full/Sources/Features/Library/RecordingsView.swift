import KSPlayer
import SwiftUI

struct RecordingsView: View {
    @State private var files: [URL] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("配置")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                Text("本地源流录像（.ts 原切片拼接）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                if files.isEmpty {
                    ContentUnavailableView("没有录像", systemImage: "folder", description: Text("播放时点录制会保存到这里"))
                } else {
                    List {
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
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.white)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { files = RecordingStore.list() }
        }
    }
}
