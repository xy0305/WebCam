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
    @State private var isMaskVisible = true
    @State private var isLocked = false
    @State private var isLandscape = false
    @State private var autoHideTask: Task<Void, Never>?
    @ObservedObject private var recs = RecordingManager.shared
    @ObservedObject private var fav = FollowingStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 播放器
            if let stream {
                KSVideoPlayerView(coordinator: coordinator, url: stream.hlsURL, options: playerOptions, title: username)
                    .ignoresSafeArea()
            } else if loading {
                ProgressView("解析直播流…").tint(.white).foregroundStyle(.white)
            } else {
                errorView
            }

            // 手势层：单击显隐、双击切横竖屏、左滑亮度右滑音量
            gestureLayer

            // 锁屏按钮（左侧中间，始终显示）
            lockButton

            // 横屏按钮（右下角常驻，不随控制层隐藏）
            orientationButton

            // 上下渐隐背景（锁定且隐藏时也跟随）
            if isMaskVisible {
                topShadowGradient
                bottomShadowGradient
            }

            // 控制层（四角布局）
            if isMaskVisible && !isLocked {
                controlsLayer
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .navigationBarHidden(true)
        .task { await resolve() }
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

    // MARK: - 错误态

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

    // MARK: - 渐隐背景

    private var topShadowGradient: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.6), .black.opacity(0.25), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 90)
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var bottomShadowGradient: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 110)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 手势层

    private var gestureLayer: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first:
                            guard !isLocked else { return }
                            toggleOrientation()
                        case .second:
                            toggleMask()
                        }
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        // 触摸时若已显示，重置自动隐藏
                        if isMaskVisible && !isLocked { scheduleAutoHide() }
                    }
            )
    }

    // MARK: - 锁屏按钮（左侧中间，始终显示）

    private var lockButton: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLocked.toggle()
                    }
                    if isLocked {
                        isMaskVisible = false
                    } else {
                        isMaskVisible = true
                        scheduleAutoHide()
                    }
                } label: {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.vertical, 44)
    }

    // MARK: - 常驻横屏按钮（右下角）

    private var orientationButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    toggleOrientation()
                    scheduleAutoHide()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isLandscape ? "rectangle.portrait.fill" : "rectangle.landscape.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(isLandscape ? "竖屏" : "横屏")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.trailing, 16)
        .padding(.bottom, 100)
    }

    // MARK: - 控制层（四角布局）

    private var controlsLayer: some View {
        ZStack {
            // 左上：返回
            VStack {
                HStack {
                    Button {
                        OrientationLock.set(.portrait)
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 4)

            // 右上：PiP + 录制（毛玻璃胶囊）
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Button {
                            startSystemPiP()
                            scheduleAutoHide()
                        } label: {
                            Image(systemName: "pip")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)

                        Button {
                            toggleRecord()
                            scheduleAutoHide()
                        } label: {
                            Image(systemName: recs.isRecording(username) ? "stop.circle.fill" : "record.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(recs.isRecording(username) ? .red : .white)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
            }
            .padding(.top, 4)

            // 中央暂停大按钮
            if !coordinator.state.isPlaying {
                Button {
                    coordinator.playerLayer?.play()
                    scheduleAutoHide()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // 左下：播放/暂停 + 收藏
            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 16) {
                        Button {
                            coordinator.state.isPlaying ? coordinator.playerLayer?.pause() : coordinator.playerLayer?.play()
                            scheduleAutoHide()
                        } label: {
                            Image(systemName: coordinator.state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)

                        Button {
                            fav.toggle(username)
                            scheduleAutoHide()
                        } label: {
                            Image(systemName: fav.isFollowing(username) ? "heart.fill" : "heart")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(fav.isFollowing(username) ? .pink : .white)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                Spacer()
            }
            .padding(.bottom, 16)

            // 右下：清晰度 + 倍速
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Menu {
                            Button("原画") { scheduleAutoHide() }
                        } label: {
                            Text("原画")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }

                        Menu {
                            Button("0.75x") { }
                            Button("1.0x") { }
                            Button("1.25x") { }
                            Button("1.5x") { }
                            Button("2.0x") { }
                        } label: {
                            Text("倍速")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
            }
            .padding(.bottom, 16)
        }
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

    private func toggleMask() {
        guard !isLocked else { return }
        withAnimation(.easeInOut(duration: 0.25)) { isMaskVisible.toggle() }
        if isMaskVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { isMaskVisible = false }
        }
    }

    private func toggleOrientation() {
        OrientationLock.toggle()
        isLandscape.toggle()
        scheduleAutoHide()
    }

    private func startSystemPiP() {
        coordinator.playerLayer?.isPipActive.toggle()
    }

    private func resolve() async {
        loading = true
        errorText = nil
        coordinator.isMaskShow = false  // 关闭 KSPlayer 自带控制层
        do { stream = try await StreamSource.resolve(username: username) }
        catch { errorText = error.localizedDescription; stream = nil }
        loading = false
        scheduleAutoHide()
    }

    private func toggleRecord() {
        guard let stream else { return }
        recs.toggle(username: username, masterURL: stream.masterURL)
    }
}

enum OrientationLock {
    /// 切换到指定方向（portrait / landscape）
    static func set(_ mask: UIInterfaceOrientationMask) {
        KSOptions.supportedInterfaceOrientations = mask

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        if let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        DispatchQueue.main.async {
            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            windowScene.requestGeometryUpdate(preferences) { _ in }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                KSOptions.supportedInterfaceOrientations = .allButUpsideDown
                if let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                    rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }

    /// 切换 iPhone 横竖屏
    static func toggle() {
        let isCurrentlyLandscape = Self.isLandscape
        set(isCurrentlyLandscape ? .portrait : .landscape)
    }

    /// 当前是否横屏
    static var isLandscape: Bool {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation
        return orientation == .landscapeLeft || orientation == .landscapeRight
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
