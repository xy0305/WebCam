import KSPlayer
import SwiftUI

struct PlayerView: View {
    let username: String
    @State private var stream: ResolvedStream?
    @State private var errorText: String?
    @State private var loading = true
    @State private var retryCount = 0
    @StateObject private var recorder = HLSRecorder()
    @ObservedObject private var fav = FollowingStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let stream {
                KSVideoPlayerView(url: stream.hlsURL, options: playerOptions, title: username)
                    .ignoresSafeArea(edges: .bottom)
            } else if loading {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("解析直播流…").foregroundStyle(.white)
                }
            } else {
                VStack(spacing: 14) {
                    Text("超时")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                    Text(errorText ?? "打不开这路直播")
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") { Task { await resolve() } }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.pink, in: Capsule())
                        .foregroundStyle(.white)
                }
            }

            if stream != nil {
                HStack(spacing: 12) {
                    Button { fav.toggle(username) } label: {
                        Image(systemName: fav.isFollowing(username) ? "heart.fill" : "heart")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(fav.isFollowing(username) ? .pink : .white)
                            .padding(12)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    Button { toggleRecord() } label: {
                        Label(recorder.isRecording ? "停止" : "录制",
                              systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(recorder.isRecording ? Color.red : Color.pink, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if recorder.isRecording {
                        Text("\(recorder.elapsedText)  \(recorder.bytesText)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 22)
            }
        }
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolve() }
        .onDisappear { if recorder.isRecording { recorder.stop() } }
        .alert("录制", isPresented: Binding(
            get: { recorder.alert != nil },
            set: { if !$0 { recorder.alert = nil } }
        )) {
            Button("好", role: .cancel) { recorder.alert = nil }
        } message: {
            Text(recorder.alert ?? "")
        }
    }

    private var playerOptions: KSOptions {
        let o = KSOptions()
        o.appendHeader(APIClient.commonHeaders)
        return o
    }

    private func resolve() async {
        loading = true
        errorText = nil
        retryCount += 1
        do {
            stream = try await StreamSource.resolve(username: username)
        } catch {
            stream = nil
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func toggleRecord() {
        if recorder.isRecording {
            recorder.stop()
        } else if let stream {
            recorder.start(username: username, hlsURL: stream.hlsURL)
        }
    }
}
