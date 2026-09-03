import KSPlayer
import SwiftUI
import UIKit

struct PlayerView: View {
    let username: String
    var room: Room? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeDismiss) private var nativeDismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var stream: ResolvedStream?
    @State private var errorText: String?
    @State private var loading = true
    @State private var isMaskVisible = true
    @State private var isLocked = false
    @State private var isPlaying = false
    @State private var isBuffering = false
    @State private var hasStarted = false
    @State private var isVerticalLive = false
    @State private var autoHideTask: Task<Void, Never>?
    @ObservedObject private var recs = RecordingManager.shared
    @ObservedObject private var fav = FollowingStore.shared

    private var displayRoom: Room {
        room ?? appState.playingRoom ?? Room(username: username)
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let fillVideo = isLandscape || isVerticalLive
            let videoHeight = fillVideo ? geo.size.height : (geo.size.width * 9 / 16)

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if !fillVideo {
                    infoPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, videoHeight)
                }

                videoArea(height: videoHeight, isLandscape: isLandscape)
                    .frame(width: geo.size.width, height: videoHeight)
            }
            .statusBarHidden(isLandscape)
            .onChange(of: isLandscape) { _, land in
                if land { isMaskVisible = true; scheduleAutoHide() }
            }
        }
        .background(Color.black)
        .navigationBarHidden(true)
        .task { await resolve() }
        .onAppear {
            coordinator.isMaskShow = false
            wireCoordinator()
            UIDevice.current.isBatteryMonitoringEnabled = true
            OrientationLock.unlock()
        }
        .onDisappear {
            autoHideTask?.cancel()
            OrientationLock.set(.portrait, keepLocked: true)
        }
        .alert("录制", isPresented: Binding(
            get: { recs.banner != nil },
            set: { if !$0 { recs.banner = nil } }
        )) {
            Button("好", role: .cancel) { recs.banner = nil }
        } message: {
            Text(recs.banner ?? "")
        }
    }

    // MARK: - 视频区域（含叠加控制）

    @ViewBuilder
    private func videoArea(height: CGFloat, isLandscape: Bool) -> some View {
        ZStack {
            Color.black

            if let stream {
                KSVideoPlayer(coordinator: coordinator, url: stream.hlsURL, options: playerOptions)
            }

            if !hasStarted && errorText == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.15)
            } else if stream == nil {
                errorView
            }

            gestureLayer

            if hasStarted && isMaskVisible && !isLocked {
                topShadowGradient
                bottomShadowGradient
            }

            if hasStarted {
                lockButton(isLandscape: isLandscape)
            }

            if hasStarted && isMaskVisible && !isLocked {
                controlsLayer(isLandscape: isLandscape)
                    .transition(.opacity)
            } else if !hasStarted {
                loadingBackButton(isLandscape: isLandscape)
            }
        }
        .frame(height: height)
        .clipped()
    }

    // MARK: - 竖屏信息栏（AngelLive：上视频下信息）

    private var infoPanel: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(displayRoom.username)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    AsyncImage(url: displayRoom.thumb) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            Circle().fill(Color.gray.opacity(0.3))
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .foregroundStyle(.white.opacity(0.8))
                                )
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 2))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayRoom.title)
                            .font(.headline)
                            .foregroundStyle(Color(white: 0.9))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text(displayRoom.viewersText)
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.7))
                        }
                    }

                    Spacer()

                    Button {
                        fav.toggle(username)
                    } label: {
                        Image(systemName: fav.isFollowing(username) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(fav.isFollowing(username) ? .red : Color(white: 0.7))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                    Text("当前平台不支持查看弹幕/评论")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.35))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.35)))
                .overlay(Capsule().stroke(Color.yellow.opacity(0.45), lineWidth: 1))

                if let subject = displayRoom.roomSubject, !subject.isEmpty {
                    Text(plainSubject(subject))
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(3)
                }

                if !displayRoom.hashtags.isEmpty {
                    FlowTags(tags: displayRoom.hashtags) { tag in
                        appState.openTag(tag)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)

            Menu {
                Button {
                    fav.toggle(username)
                } label: {
                    Label(fav.isFollowing(username) ? "取消收藏" : "收藏",
                          systemImage: fav.isFollowing(username) ? "heart.slash" : "heart")
                }
                if let url = URL(string: "https://chaturbate.com/\(username)/") {
                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.10, blue: 0.08),
                    Color(red: 0.07, green: 0.06, blue: 0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
        .allowsHitTesting(false)
    }

    private var bottomShadowGradient: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 80)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 手势：单击显隐、双击切横竖屏

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
    }

    private func loadingBackButton(isLandscape: Bool) -> some View {
        VStack {
            HStack {
                Button { handleBack(isLandscape: isLandscape) } label: {
                    Image(systemName: "chevron.left")
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
        .padding(.leading, isLandscape ? 25 : 0)
    }

    // MARK: - 锁屏（左侧中部，始终可点）

    private func lockButton(isLandscape: Bool) -> some View {
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
                .padding(.leading, isLandscape ? 25 : 12)
                Spacer()
            }
            Spacer()
        }
        .opacity(isMaskVisible || isLocked ? 1 : 0)
        .allowsHitTesting(isMaskVisible || isLocked)
    }

    // MARK: - 四角控制（对齐 AngelLive）

    private func controlsLayer(isLandscape: Bool) -> some View {
        let inset: CGFloat = isLandscape ? 25 : 0
        return ZStack {
            if isLandscape {
                VStack {
                    landscapeStatusBar
                        .padding(.top, 5)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // 左上：返回
            VStack {
                HStack {
                    Button { handleBack(isLandscape: isLandscape) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, inset)
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 4)

            // 右上：PiP + 录制
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 16) {
                        iconButton("pip") {
                            startSystemPiP()
                        }
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
                    .frame(height: 50)
                    .padding(.trailing, inset)
                }
                Spacer()
            }
            .padding(.top, 4)

            // 中央暂停大按钮（首帧出来后、用户暂停时才显示）
            if !isPlaying && !isBuffering && stream != nil {
                Button {
                    coordinator.playerLayer?.play()
                    isPlaying = true
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

            // 左下：播放/暂停 + 刷新
            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 16) {
                        iconButton(isPlaying ? "pause.fill" : "play.fill") {
                            if isPlaying {
                                coordinator.playerLayer?.pause()
                                isPlaying = false
                            } else {
                                coordinator.playerLayer?.play()
                                isPlaying = true
                            }
                        }
                        iconButton("arrow.counterclockwise") {
                            Task { await resolve() }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.leading, inset)
                    Spacer()
                }
            }
            .padding(.bottom, 12)

            // 右下：清晰度 + 全屏
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Text("原画")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)

                        if !isVerticalLive {
                            Button {
                                toggleOrientation()
                            } label: {
                                Image(systemName: isLandscape
                                      ? "arrow.down.right.and.arrow.up.left"
                                      : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.trailing, inset)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleAutoHide()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }

    private var landscapeStatusBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Text(Self.timeFormatter.string(from: context.date))
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: batteryIconName)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white)
        }
    }

    private var batteryIconName: String {
        let level = UIDevice.current.batteryLevel
        if level < 0 { return "battery.100" }
        switch level {
        case 0..<0.2: return "battery.0"
        case 0.2..<0.45: return "battery.25"
        case 0.45..<0.7: return "battery.50"
        case 0.7..<0.95: return "battery.75"
        default: return "battery.100"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

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

    private func wireCoordinator() {
        coordinator.isMaskShow = false
        coordinator.onStateChanged = { layer, state in
            isPlaying = state.isPlaying
            isBuffering = state == .buffering || state == .preparing
            if state.isPlaying || state == .readyToPlay || state == .paused {
                hasStarted = true
            }
            if state == .readyToPlay {
                let size = layer.player.naturalSize
                if size.width > 1, size.height > 1 {
                    isVerticalLive = (size.width / size.height) < 1.0
                    if isVerticalLive {
                        OrientationLock.set(.portrait, keepLocked: true)
                    }
                }
            }
        }
    }

    private func toggleMask() {
        if isLocked {
            withAnimation(.easeInOut(duration: 0.25)) { isMaskVisible.toggle() }
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { isMaskVisible.toggle() }
        if isMaskVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { isMaskVisible = false }
        }
    }

    private func handleBack(isLandscape: Bool) {
        if isLandscape {
            OrientationLock.set(.portrait)
        } else {
            OrientationLock.set(.portrait, keepLocked: true)
            nativeDismiss()
        }
    }

    private func toggleOrientation() {
        if isVerticalLive {
            // 竖屏直播锁竖屏，不允许横屏全屏
            return
        }
        OrientationLock.toggle()
        scheduleAutoHide()
    }

    private func startSystemPiP() {
        coordinator.playerLayer?.isPipActive.toggle()
        scheduleAutoHide()
    }

    private func resolve() async {
        loading = true
        errorText = nil
        coordinator.isMaskShow = false
        hasStarted = false
        do { stream = try await StreamSource.resolve(username: username) }
        catch { errorText = error.localizedDescription; stream = nil }
        loading = false
        wireCoordinator()
        scheduleAutoHide()
    }

    private func toggleRecord() {
        guard let stream else { return }
        recs.toggle(
            username: username,
            videoPlaylist: stream.videoPlaylist,
            audioPlaylist: stream.audioPlaylist,
            masterURL: stream.masterURL
        )
    }
}

enum OrientationLock {
    static func set(_ mask: UIInterfaceOrientationMask, keepLocked: Bool = false) {
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

            guard !keepLocked else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                KSOptions.supportedInterfaceOrientations = .allButUpsideDown
                if let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                    rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }

    static func unlock() {
        KSOptions.supportedInterfaceOrientations = .allButUpsideDown
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    static func toggle() {
        set(isLandscape ? .portrait : .landscapeRight)
    }

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

private func plainSubject(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace })
        .filter { !$0.hasPrefix("#") }
        .joined(separator: " ")
}

private struct FlowTags: View {
    let tags: [String]
    var onTap: (String) -> Void

    var body: some View {
        TagFlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    onTap(tag)
                } label: {
                    Text("#\(tag)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
