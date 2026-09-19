import KSPlayer
import SwiftUI
import UIKit

/// 115 网盘原画：可横屏，毛玻璃控件，左右滑亮度/音量。
struct Pan115PlayerView: View {
    let url: URL
    let title: String
    @Environment(\.nativeDismiss) private var nativeDismiss
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var isPlaying = false
    @State private var isBuffering = true
    @State private var showChrome = true
    @State private var current: Double = 0
    @State private var total: Double = 1
    @State private var isSeeking = false
    @State private var hideTask: Task<Void, Never>?
    @State private var swipeKind: EdgeSwipeKind?
    @State private var swipeValue: CGFloat = 0
    @State private var swipeBase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let land = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                    .onPlay { cur, tot in
                        if !isSeeking {
                            current = max(0, cur)
                            if tot > 1.5 { total = tot }
                        }
                    }
                    .onStateChanged { _, state in
                        isPlaying = state.isPlaying
                        isBuffering = !state.isPlaying && current < 0.3 && state != .playedToTheEnd
                        if state == .playedToTheEnd {
                            isPlaying = false
                            showChrome = true
                        }
                    }
                    .ignoresSafeArea()

                gestureLayer(size: geo.size)
                    .allowsHitTesting(!showChrome || swipeKind != nil)

                if isBuffering && current < 0.4 {
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
                        .frame(height: 180)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    VStack(spacing: 0) {
                        topBar(land: land, safeTop: windowSafeTop(geo))
                        Spacer()
                        centerControls
                        Spacer()
                        bottomBar(land: land, safeBottom: windowSafeBottom(geo))
                    }
                    .zIndex(2)
                    .transition(.opacity)
                }
            }
            .statusBarHidden(true)
        }
        .background(Color.black)
        .onAppear {
            coordinator.isMaskShow = false
            OrientationLock.unlock()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
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
                Text("115 原画")
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

    private var centerControls: some View {
        HStack(spacing: 44) {
            controlButton("gobackward.10") { seekBy(-10) }
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            controlButton("goforward.10") { seekBy(10) }
        }
    }

    private func bottomBar(land: Bool, safeBottom: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(format(current))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .leading)
                Slider(
                    value: $current,
                    in: 0...max(total, 1),
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if editing {
                            hideTask?.cancel()
                        } else {
                            coordinator.seek(time: current)
                            scheduleHide()
                        }
                    }
                )
                .tint(.white)
                Text(format(total))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .trailing)
            }
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

    private func controlButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var options: KSOptions {
        let o = KSOptions()
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        o.videoAdaptable = false
        o.appendHeader(Pan115API.playHeaders())
        return o
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

    private func seekBy(_ delta: Double) {
        let span = max(total, current + abs(delta), 1)
        let t = min(max(0, current + delta), span)
        current = t
        coordinator.seek(time: t)
        scheduleHide()
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        if showChrome { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !isSeeking, swipeKind == nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showChrome = false }
        }
    }

    private func format(_ t: Double) -> String {
        let s = max(0, Int(t))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
