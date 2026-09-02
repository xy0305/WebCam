import KSPlayer
import SwiftUI
import UIKit

struct PlayerView: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var stream: ResolvedStream?
    @State private var errorText: String?
    @State private var loading = true
    @State private var showChrome = true
    @State private var locked = false
    @State private var isLandscape = false
    @State private var hideChromeTask: Task<Void, Never>?
    @ObservedObject private var recs = RecordingManager.shared
    @ObservedObject private var fav = FollowingStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let stream {
                KSVideoPlayerView(coordinator: coordinator, url: stream.hlsURL, options: playerOptions, title: username)
                    .ignoresSafeArea()
            } else if loading {
                ProgressView("解析直播流…").tint(.white).foregroundStyle(.white)
            } else {
                errorView
            }

            // 手势层
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }
                .gesture(TapGesture(count: 2).onEnded { dismiss() })

            // 锁屏按钮（右侧中部，常驻可见，便于唤回）
            lockButton

            // 控制栏（上下渐隐）
            if showChrome {
                overlayChrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .navigationBarHidden(true)
        .task { await resolve(); scheduleChromeHide() }
        .onDisappear { OrientationLock.set(.portrait) }
        .alert("录制", isPresented: Binding(
            get: { recs.banner != nil },
            set: { if !$0 { recs.banner = nil } }
        )) {
            Button("好", role: .cancel) { recs.banner = nil }
        } message: {
            Text(recs.banner ?? "")
        }
    }

    // MARK: - 错误 / 空态

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text(errorText ?? "打不开")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
            Button("重试") { Task { await resolve() } }
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.2), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    // MARK: - 控制栏

    private var overlayChrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .foregroundStyle(.white)
        .allowsHitTesting(!locked)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            circleBtn("chevron.down", size: 30) {
                OrientationLock.set(.portrait)
                dismiss()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(username).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("LIVE").font(.caption2.weight(.bold))
                }
            }

            Spacer()

            circleBtn(recs.isRecording(username) ? "stop.circle.fill" : "record.circle", size: 30) {
                toggleRecord()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 22) {
            // 左侧：收藏
            circleBtn(fav.isFollowing(username) ? "heart.fill" : "heart", size: 30) {
                fav.toggle(username)
                scheduleChromeHide()
            }

            if recs.isRecording(username) {
                Text(recs.session(for: username)?.elapsedText ?? "REC")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            // 横竖屏切换（醒目按钮）
            Button {
                toggleOrientation()
                scheduleChromeHide()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isLandscape ? "rectangle.portrait.fill" : "rectangle.landscape.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(isLandscape ? "竖屏" : "横屏")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.35), in: Capsule())
            }
            .buttonStyle(.plain)

            // 清晰度
            Menu {
                Button("原画") { scheduleChromeHide() }
            } label: {
                HStack(spacing: 4) {
                    Text("原画")
                    Image(systemName: "chevron.up").font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            }

            // 倍速
            Menu {
                Button("0.75x") { }
                Button("1.0x") { }
                Button("1.25x") { }
                Button("1.5x") { }
                Button("2.0x") { }
            } label: {
                Text("倍速").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }

            // PiP
            circleBtn("pip.enter", size: 28) {
                startSystemPiP()
                scheduleChromeHide()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 14)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 锁屏按钮（右侧中部常驻，锁定后仍可见以便解锁）

    private var lockButton: some View {
        VStack {
            Spacer()
            circleBtn(locked ? "lock.fill" : "lock.open", size: 36) {
                locked.toggle()
                withAnimation(.easeInOut(duration: 0.25)) { showChrome = !locked }
                if !locked { scheduleChromeHide() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 20)
        .padding(.vertical, 44)
    }

    private func circleBtn(_ name: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 播放器选项

    private var playerOptions: KSOptions {
        let o = KSOptions()
        o.appendHeader(APIClient.commonHeaders)
        KSOptions.isAutoPlay = true
        o.videoAdaptable = false
        o.canStartPictureInPictureAutomaticallyFromInline = true
        return o
    }

    // MARK: - 交互

    private func toggleChrome() {
        guard !locked else { return }
        withAnimation(.easeInOut(duration: 0.25)) { showChrome.toggle() }
        if showChrome { scheduleChromeHide() }
    }

    private func scheduleChromeHide() {
        hideChromeTask?.cancel()
        hideChromeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showChrome = false }
        }
    }

    private func toggleOrientation() {
        isLandscape.toggle()
        OrientationLock.set(isLandscape ? .landscape : .portrait)
    }

    private func startSystemPiP() {
        coordinator.playerLayer?.isPipActive.toggle()
    }

    private func resolve() async {
        loading = true
        errorText = nil
        coordinator.isMaskShow = false
        do { stream = try await StreamSource.resolve(username: username) }
        catch { errorText = error.localizedDescription; stream = nil }
        loading = false
    }

    private func toggleRecord() {
        guard let stream else { return }
        // 录制用官方 master（音视频一体的完整 playlist），而非 data: 迷你 master
        recs.toggle(username: username, masterURL: stream.masterURL)
        scheduleChromeHide()
    }
}

enum OrientationLock {
    static func set(_ mask: UIInterfaceOrientationMask) {
        // 更新 AppDelegate 支持的方向
        AppDelegate.supportedOrientations = mask

        // 请求几何更新，让旋转立即生效
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }

        // 强制刷新支持的方向
        if let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.keyWindow?.rootViewController {
            root.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
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
                        Text(name).font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.trailing, 8)
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
        o.videoAdaptable = false
        o.canStartPictureInPictureAutomaticallyFromInline = true
        return o
    }
}
