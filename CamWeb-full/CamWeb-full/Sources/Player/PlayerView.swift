import KSPlayer
import SwiftUI
import UIKit

enum PlayLayout: String, CaseIterable {
    case portrait = "竖屏"
    case landscape = "横屏"
    case mini = "小窗"
}

struct PlayerView: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var stream: ResolvedStream?
    @State private var errorText: String?
    @State private var loading = true
    @State private var showChrome = true
    @State private var layout: PlayLayout = .portrait
    @State private var paused = false
    @State private var speed: Float = 1
    @State private var showSpeed = false
    @ObservedObject private var recs = RecordingManager.shared
    @ObservedObject private var fav = FollowingStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let stream {
                KSVideoPlayerView(url: stream.hlsURL, options: playerOptions, title: username)
                    .ignoresSafeArea()
            } else if loading {
                ProgressView("解析直播流…").tint(.white).foregroundStyle(.white)
            } else {
                VStack(spacing: 12) {
                    Text("超时").font(.caption.bold()).padding(6).background(Color.red).foregroundStyle(.white)
                    Text(errorText ?? "打不开").foregroundStyle(.white)
                    Button("重试") { Task { await resolve() } }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.pink, in: Capsule())
                }
            }

            if showChrome {
                chrome
            }
        }
        .statusBarHidden(layout == .landscape)
        .navigationBarHidden(true)
        .onTapGesture { showChrome.toggle() }
        .task { await resolve() }
        .onDisappear {
            if layout != .mini { OrientationLock.set(.portrait) }
        }
        .alert("录制", isPresented: Binding(
            get: { recs.banner != nil },
            set: { if !$0 { recs.banner = nil } }
        )) {
            Button("好", role: .cancel) { recs.banner = nil }
        } message: {
            Text(recs.banner ?? "")
        }
        .confirmationDialog("倍速", isPresented: $showSpeed, titleVisibility: .visible) {
            Button("0.75x") { speed = 0.75 }
            Button("1.0x") { speed = 1 }
            Button("1.25x") { speed = 1.25 }
            Button("1.5x") { speed = 1.5 }
            Button("2.0x") { speed = 2 }
        }
    }

    private var chrome: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                OrientationLock.set(.portrait)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(.black.opacity(0.35), in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(username)
                    .font(.headline)
                    .lineLimit(1)
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
            }
            Spacer()
            HStack(spacing: 10) {
                iconBtn("pip.enter") { enterMini() }
                iconBtn(fav.isFollowing(username) ? "heart.fill" : "heart") { fav.toggle(username) }
                iconBtn(recs.isRecording(username) ? "stop.circle.fill" : "record.circle") { toggleRecord() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(recs.session(for: username)?.elapsedText ?? (recs.isRecording(username) ? "REC" : "LIVE"))
                    .font(.system(.caption, design: .monospaced))
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.pink).frame(width: 8, height: 3)
                    }
                Text(recs.session(for: username)?.bytesText ?? "00:00")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 12)

            HStack(spacing: 14) {
                Button {
                    paused.toggle()
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                }
                Spacer()
                modeBtn(.portrait)
                modeBtn(.landscape)
                modeBtn(.mini)
                Button("原画") { }
                    .font(.subheadline.weight(.semibold))
                Button("倍速") { showSpeed = true }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        )
    }

    private func modeBtn(_ mode: PlayLayout) -> some View {
        Button(mode.rawValue) { apply(mode) }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(layout == mode ? Color.pink : Color.white.opacity(0.15), in: Capsule())
    }

    private func iconBtn(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .padding(8)
                .background(.black.opacity(0.35), in: Circle())
        }
    }

    private var playerOptions: KSOptions {
        let o = KSOptions()
        o.appendHeader(APIClient.commonHeaders)
        KSOptions.isAutoPlay = !paused
        o.canStartPictureInPictureAutomaticallyFromInline = true
        return o
    }

    private func apply(_ mode: PlayLayout) {
        layout = mode
        switch mode {
        case .portrait:
            OrientationLock.set(.portrait)
        case .landscape:
            OrientationLock.set(.landscape)
        case .mini:
            enterMini()
        }
    }

    private func enterMini() {
        guard let stream else { return }
        appState.startMini(username: username, url: stream.hlsURL)
        OrientationLock.set(.portrait)
        dismiss()
    }

    private func resolve() async {
        loading = true
        errorText = nil
        do { stream = try await StreamSource.resolve(username: username) }
        catch { errorText = error.localizedDescription; stream = nil }
        loading = false
    }

    private func toggleRecord() {
        if let stream {
            recs.toggle(username: username, hlsURL: stream.hlsURL)
        }
    }
}

enum OrientationLock {
    static func set(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

struct MiniPlayerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let name = appState.miniUsername, let url = appState.miniURL {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    KSVideoPlayerView(url: url, options: miniOptions, title: name)
                        .frame(height: 120)
                    HStack {
                        Button {
                            appState.stopMini()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .padding(6)
                                .background(.black.opacity(0.45), in: Circle())
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.trailing, 8)
                    }
                    .padding(6)
                }
            }
            .frame(width: 210)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
            .padding(.trailing, 12)
            .padding(.bottom, 88)
        }
    }

    private var miniOptions: KSOptions {
        let o = KSOptions()
        o.appendHeader(APIClient.commonHeaders)
        KSOptions.isAutoPlay = true
        o.canStartPictureInPictureAutomaticallyFromInline = true
        return o
    }
}
