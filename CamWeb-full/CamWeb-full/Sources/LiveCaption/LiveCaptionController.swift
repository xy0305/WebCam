import Foundation
import Observation

/// Player-facing controller: preference + session, with UI-first disable.
/// Does not change player quality selection or reuse single-use Chaturbate play tokens.
@MainActor
@Observable
final class LiveCaptionController {
    let preference = LiveCaptionPreference()
    let session = LiveCaptionSession()

    private(set) var showsCaptions = false
    private(set) var overlayLine: LiveCaptionLine?
    private(set) var overlayStatus = ""

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    private var lastIdentity: String?
    private var lastRoom: Room?
    private var lastStream: ResolvedStream?

    init() {
        showsCaptions = preference.isEnabled
        syncTask = Task { [weak self] in
            await self?.mirrorSession()
        }
        // Whisper finished downloading while captions are on → restart once to switch from Apple Speech.
        LiveCaptionModelStore.shared.onWhisperReady = { [weak self] model in
            guard let self, self.showsCaptions, model == LiveCaptionPreference.whisperModel,
                  LiveCaptionPreference.asr == .whisper, let room = self.lastRoom, let stream = self.lastStream else { return }
            self.startSession(room: room, stream: stream)
        }
    }

    /// First use of Whisper: kick off the model download (progress shown in overlay + Settings).
    private func ensureWhisperModel() {
        guard LiveCaptionPreference.asr == .whisper else { return }
        let model = LiveCaptionPreference.whisperModel
        let store = LiveCaptionModelStore.shared
        switch store.whisperState(model) {
        case .notDownloaded, .failed:
            store.downloadWhisper(model)
        default:
            break
        }
    }

    private func startSession(room: Room, stream: ResolvedStream) {
        lastRoom = room
        lastStream = stream
        lastIdentity = streamIdentity(for: stream)
        let source = currentSource(room: room, stream: stream)
        let refresh = makeRefresher(room: room)
        Task { await session.start(source: source, refresh: refresh) }
    }


    var translationBridge: AnyObject? { session.translationBridge }

    private func requestOptions(for room: Room, stream: ResolvedStream) -> (headers: [String: String], userAgent: String) {
        switch room.platform {
        case .stripchat:
            return ([
                "User-Agent": APIClient.userAgent,
                "Accept": "*/*",
                "Referer": "https://zh.stripchat.com/",
                "Origin": "https://zh.stripchat.com",
            ], APIClient.userAgent)
        case .panda:
            var h: [String: String] = [
                "User-Agent": PandaAPI.userAgent,
                "Accept": "*/*",
                "Referer": stream.requestContext.referer,
                "Origin": "https://www.pandalive.co.kr",
            ]
            if let cookie = PandaSession.shared.cookieHeader { h["Cookie"] = cookie }
            return (h, PandaAPI.userAgent)
        case .chaturbate:
            return (APIClient.hlsHeaders, APIClient.userAgent)
        }
    }

    /// Placeholder source from the current player stream. For Chaturbate, `requiresFreshPlaylist`
    /// forces the session to mint its own token via the refresher — never reopen the player's URL.
    func currentSource(room: Room, stream: ResolvedStream) -> LiveCaptionSource {
        let req = requestOptions(for: room, stream: stream)
        let needsFresh = room.platform == .chaturbate
        let url: URL
        if needsFresh {
            // Identity only — session will refresh before opening.
            url = stream.masterURL.scheme == "data" ? stream.videoPlaylist : stream.masterURL
        } else if let audio = stream.audioPlaylist {
            url = audio
        } else if stream.masterURL.scheme != "data" {
            url = stream.masterURL
        } else {
            url = stream.videoPlaylist
        }
        return LiveCaptionSource(
            url: url,
            headers: req.headers,
            userAgent: req.userAgent,
            requiresFreshPlaylist: needsFresh
        )
    }

    /// Mint a caption-only play URL. Separate from the player session / quality lock.
    ///
    /// Chaturbate edge master tokens are single-use. `StreamSource.resolve` calls `HLSMaster.lock`,
    /// which GETs the master once to build the highest-quality mini playlist — that burns the token.
    /// Returning that already-used `masterURL` made `fetchPlaylist` hit HTTP 403
    /// (`字幕音频地址不可用: HTTP 403`). Captions mint an unused master via `mintCaptionMaster`
    /// instead; `LiveCaptionSession` fetches it once and opens the audio media playlist.
    func makeRefresher(room: Room) -> LiveCaptionSession.SourceRefresher {
        return {
            switch room.platform {
            case .chaturbate:
                guard let master = try? await StreamSource.mintCaptionMaster(username: room.username) else {
                    return nil
                }
                return LiveCaptionSource(
                    url: master,
                    headers: APIClient.hlsHeaders,
                    userAgent: APIClient.userAgent,
                    requiresFreshPlaylist: true
                )
            case .stripchat, .panda:
                guard let fresh = try? await StreamSource.resolve(room: room) else { return nil }
                let headers: [String: String]
                let ua: String
                switch room.platform {
                case .stripchat:
                    headers = [
                        "User-Agent": APIClient.userAgent,
                        "Accept": "*/*",
                        "Referer": "https://zh.stripchat.com/",
                        "Origin": "https://zh.stripchat.com",
                    ]
                    ua = APIClient.userAgent
                case .panda:
                    var h: [String: String] = [
                        "User-Agent": PandaAPI.userAgent,
                        "Accept": "*/*",
                        "Referer": fresh.requestContext.referer,
                        "Origin": "https://www.pandalive.co.kr",
                    ]
                    if let cookie = PandaSession.shared.cookieHeader { h["Cookie"] = cookie }
                    headers = h
                    ua = PandaAPI.userAgent
                case .chaturbate:
                    headers = APIClient.hlsHeaders
                    ua = APIClient.userAgent
                }
                // Reusable playlists: prefer audio media URI when resolve already extracted it;
                // otherwise the master / video playlist (session will classify).
                let url: URL
                if let audio = fresh.audioPlaylist {
                    url = audio
                } else if fresh.masterURL.scheme != "data" {
                    url = fresh.masterURL
                } else {
                    url = fresh.videoPlaylist
                }
                return LiveCaptionSource(
                    url: url,
                    headers: headers,
                    userAgent: ua,
                    requiresFreshPlaylist: false
                )
            }
        }
    }

    private func streamIdentity(for stream: ResolvedStream) -> String {
        let url = stream.masterURL.scheme == "data" ? stream.videoPlaylist : stream.masterURL
        return LiveCaptionHLS.streamIdentity(url)
    }

    /// Toggle from the player chrome. OFF is UI-first, then async teardown.
    func setEnabled(_ enabled: Bool, room: Room, stream: ResolvedStream?) {
        preference.isEnabled = enabled
        showsCaptions = enabled
        if !enabled {
            overlayLine = nil
            overlayStatus = ""
            Task { await session.stop(clearText: true) }
            return
        }
        ensureWhisperModel()
        guard let stream else {
            overlayStatus = "等待播放地址…"
            return
        }
        startSession(room: room, stream: stream)
    }

    func handleStreamChanged(room: Room, stream: ResolvedStream?) {
        guard preference.isEnabled, showsCaptions, let stream else { return }
        let identity = streamIdentity(for: stream)
        if lastIdentity == identity { return }
        lastIdentity = identity
        lastRoom = room
        lastStream = stream
        let source = currentSource(room: room, stream: stream)
        let refresh = makeRefresher(room: room)
        Task { await session.retarget(source: source, refresh: refresh) }
    }

    func resumeIfNeeded(room: Room, stream: ResolvedStream?) {
        guard preference.isEnabled else { return }
        showsCaptions = true
        ensureWhisperModel()
        guard let stream else { return }
        startSession(room: room, stream: stream)
    }

    func handlePlaybackBusy(_ busy: Bool) {
        guard showsCaptions else { return }
        session.holdForBandwidth(busy)
    }

    func shutdown() {
        showsCaptions = false
        overlayLine = nil
        overlayStatus = ""
        Task { await session.stop(clearText: true) }
    }

    private func mirrorSession() async {
        while !Task.isCancelled {
            if showsCaptions {
                overlayLine = session.latest
                let whisper = LiveCaptionModelStore.shared.whisperState(LiveCaptionPreference.whisperModel)
                if session.phase == .starting || session.phase == .failed {
                    overlayStatus = session.statusMessage
                } else if overlayLine == nil {
                    if session.whisperFallback, whisper.isBusy {
                        overlayStatus = "Whisper \(whisper.label)（暂用 Apple 语音）"
                    } else {
                        overlayStatus = session.statusMessage
                    }
                } else {
                    overlayStatus = ""
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
