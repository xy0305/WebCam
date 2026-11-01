import KSPlayer
import SwiftUI
import UIKit

/// Paste-only RTMP / HLS / media playback. Does not touch plugin max-quality lock paths.
struct DirectStreamPlayerView: View {
    let url: URL

    @Environment(\.nativeDismiss) private var nativeDismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var isPlaying = false
    @State private var isBuffering = true
    @State private var hasStarted = false
    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var swipeKind: EdgeSwipeKind?
    @State private var swipeValue: CGFloat = 0
    @State private var swipeBase: CGFloat = 0
    @State private var playerOptions: KSOptions
    @State private var liveCaption = LiveCaptionController()
    @State private var captionTip = ""

    private var title: String { DirectStreamURL.displayTitle(url) }
    private var useFFmpeg: Bool { DirectStreamURL.needsFFmpeg(url) }
    private var captionOK: Bool { DirectStreamURL.supportsLiveCaption(url) }
    private var syntheticRoom: Room {
        Room(
            platform: .direct,
            username: title,
            displayName: title,
            roomSubject: url.absoluteString
        )
    }
    private var syntheticStream: ResolvedStream {
        ResolvedStream(
            username: title,
            requestContext: HLSRequestContext(referer: "", origin: nil),
            hlsURL: url,
            masterURL: url,
            videoPlaylist: url,
            audioPlaylist: nil,
            status: "direct"
        )
    }

    init(url: URL) {
        self.url = url
        _playerOptions = State(initialValue: Self.makeOptions(url: url))
    }

    var body: some View {
        GeometryReader { geo in
            let land = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                KSVideoPlayer(coordinator: coordinator, url: url, options: playerOptions)
                    .onStateChanged { _, state in
                        isPlaying = state.isPlaying
                        isBuffering = state == .buffering || state == .preparing
                        liveCaption.handlePlaybackBusy(isBuffering)
                        if state.isPlaying || state == .readyToPlay || state == .paused {
                            let first = !hasStarted
                            hasStarted = true
                            if first, captionOK, liveCaption.preference.isEnabled {
                                liveCaption.resumeIfNeeded(room: syntheticRoom, stream: syntheticStream)
                            }
                        }
                    }
                    .ignoresSafeArea()

                gestureLayer(size: geo.size)
                    .allowsHitTesting(!showChrome || swipeKind != nil)

                if isBuffering && !hasStarted {
                    ProgressView().tint(.white).scaleEffect(1.2)
                }

                if let swipeKind {
                    EdgeSwipeHud(kind: swipeKind, value: swipeValue)
                }

                if showChrome {
                    LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 160)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    VStack(spacing: 0) {
                        topBar(land: land, safeTop: windowSafeTop(geo))
                        Spacer()
                        centerPlay
                        Spacer()
                        bottomBar(land: land, safeBottom: windowSafeBottom(geo))
                    }
                    .zIndex(2)
                    .transition(.opacity)
                }

                if liveCaption.showsCaptions {
                    LiveCaptionOverlay(
                        line: liveCaption.overlayLine,
                        statusMessage: liveCaption.overlayStatus.isEmpty ? captionTip : liveCaption.overlayStatus,
                        reduceMotion: reduceMotion,
                        allowEnglish: LiveCaptionPreference.showEnglishSource
                    )
                } else if !captionTip.isEmpty, showChrome {
                    Text(captionTip)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, land ? 28 : 56)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }

                LiveCaptionTranslationHost(bridge: liveCaption.translationBridge)
            }
            .statusBarHidden(true)
        }
        .background(Color.black)
        .onAppear {
            coordinator.isMaskShow = false
            OrientationLock.unlock()
            coordinator.playerLayer?.play()
            scheduleHide()
            if !captionOK {
                captionTip = "RTMP 暂不支持实时翻译（可正常播放）"
            }
            liveCaption.handleStreamChanged(room: syntheticRoom, stream: syntheticStream)
        }
        .onDisappear {
            hideTask?.cancel()
            liveCaption.shutdown()
            coordinator.playerLayer?.pause()
            OrientationLock.set(.portrait, keepLocked: true)
        }
    }

    private func topBar(land: Bool, safeTop: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button {
                coordinator.playerLayer?.pause()
                if land {
                    OrientationLock.set(.portrait)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { nativeDismiss() }
                } else {
                    nativeDismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("打开地址 · \(DirectStreamURL.schemeLabel(url))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button { OrientationLock.toggle() } label: {
                Image(systemName: land ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, land ? 28 : 16)
        .padding(.top, land ? max(12, safeTop) : max(54, safeTop + 6))
    }

    private var centerPlay: some View {
        Button { togglePlay() } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func bottomBar(land: Bool, safeBottom: CGFloat) -> some View {
        HStack(spacing: 16) {
            Button {
                toggleCaption()
            } label: {
                Image(systemName: liveCaption.showsCaptions ? "character.bubble.fill" : "character.bubble")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(liveCaption.showsCaptions ? AppTheme.accent : .white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(liveCaption.showsCaptions ? "关闭实时翻译" : "开启实时翻译")

            Spacer()

            Text(url.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, land ? 32 : 18)
        .padding(.bottom, max(land ? 16 : 24, safeBottom + 8))
    }

    private func gestureLayer(size: CGSize) -> some View {
        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        let edge = size.width * 0.28
                        if swipeKind == nil {
                            if abs(value.translation.height) < abs(value.translation.width) { return }
                            if value.startLocation.x < edge {
                                swipeKind = .brightness
                                swipeBase = ScreenBrightness.current
                            } else if value.startLocation.x > size.width - edge {
                                swipeKind = .volume
                                swipeBase = CGFloat(SystemVolume.current)
                            } else {
                                return
                            }
                            hideTask?.cancel()
                        }
                        let delta = -value.translation.height / 220
                        let next = min(1, max(0, swipeBase + delta))
                        swipeValue = next
                        if swipeKind == .brightness {
                            ScreenBrightness.set(next)
                        } else if swipeKind == .volume {
                            SystemVolume.set(Float(next))
                        }
                    }
                    .onEnded { _ in
                        swipeKind = nil
                        scheduleHide()
                    }
            )
            .onTapGesture(count: 2) { togglePlay() }
            .onTapGesture { toggleChrome() }
    }

    private static func makeOptions(url: URL) -> KSOptions {
        let o = KSOptions()
        let ffmpeg = DirectStreamURL.needsFFmpeg(url)
        if ffmpeg {
            KSOptions.firstPlayerType = KSMEPlayer.self
            KSOptions.secondPlayerType = KSAVPlayer.self
            // RTMP: timeouts in microseconds; listen_timeout=-1 for rtmp client mode.
            o.formatContextOptions["rw_timeout"] = 15_000_000
            o.formatContextOptions["timeout"] = 15_000_000
            o.formatContextOptions["listen_timeout"] = -1
            o.formatContextOptions["reconnect"] = 1
            o.formatContextOptions["reconnect_streamed"] = 1
            o.probesize = 65_536
            o.maxAnalyzeDuration = 2_000_000
            o.nobuffer = true
        } else {
            KSOptions.firstPlayerType = KSAVPlayer.self
            KSOptions.secondPlayerType = KSMEPlayer.self
            o.appendHeader([
                "User-Agent": APIClient.userAgent,
                "Accept": "*/*",
            ])
        }
        KSOptions.isAutoPlay = true
        o.videoAdaptable = false
        o.canStartPictureInPictureAutomaticallyFromInline = true
        return o
    }

    private func toggleCaption() {
        if !captionOK {
            captionTip = "RTMP 暂不支持实时翻译（可正常播放）"
            showChrome = true
            scheduleHide()
            return
        }
        captionTip = ""
        let next = !liveCaption.showsCaptions
        liveCaption.setEnabled(next, room: syntheticRoom, stream: syntheticStream)
        scheduleHide()
    }

    private func togglePlay() {
        if isPlaying {
            coordinator.playerLayer?.pause()
            isPlaying = false
        } else {
            coordinator.playerLayer?.play()
            isPlaying = true
        }
        scheduleHide()
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        if showChrome { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showChrome = false }
        }
    }

    private func windowSafeTop(_ geo: GeometryProxy) -> CGFloat {
        max(geo.safeAreaInsets.top, keyWindowInsets.top)
    }

    private func windowSafeBottom(_ geo: GeometryProxy) -> CGFloat {
        max(geo.safeAreaInsets.bottom, keyWindowInsets.bottom)
    }

    private var keyWindowInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }
}
