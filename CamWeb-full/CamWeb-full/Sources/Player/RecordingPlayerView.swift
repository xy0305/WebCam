import KSPlayer
import SwiftUI

/// 本地录像回放：全屏、可拖进度条，不走 KSPlayer 自带那套控件。
struct RecordingPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var isPlaying = false
    @State private var showChrome = true
    @State private var current: Double = 0
    @State private var total: Double = 1
    @State private var isSeeking = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .onPlay { cur, tot in
                    if !isSeeking {
                        current = max(0, cur)
                        total = max(tot, 1)
                    }
                }
                .onStateChanged { _, state in
                    isPlaying = state.isPlaying
                    if state == .playedToTheEnd {
                        isPlaying = false
                    }
                }
                .ignoresSafeArea()

            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { toggleChrome() }

            if showChrome {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            coordinator.isMaskShow = false
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            coordinator.playerLayer?.pause()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                coordinator.playerLayer?.pause()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(url.deletingPathExtension().lastPathComponent)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(format(current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 44, alignment: .leading)

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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 44, alignment: .trailing)
            }

            Button {
                if isPlaying {
                    coordinator.playerLayer?.pause()
                    isPlaying = false
                } else {
                    coordinator.playerLayer?.play()
                    isPlaying = true
                }
                scheduleHide()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var options: KSOptions {
        let o = KSOptions()
        KSOptions.isAutoPlay = true
        o.videoAdaptable = false
        return o
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        if showChrome { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !isSeeking else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showChrome = false }
        }
    }

    private func format(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
