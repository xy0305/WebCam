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

    init() {
        showsCaptions = preference.isEnabled
        syncTask = Task { [weak self] in
            await self?.mirrorSession()
        }
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
    func makeRefresher(room: Room) -> LiveCaptionSession.SourceRefresher {
        return {
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
            // Prefer the fresh master so LiveCaptionHLS can pick the audio-only media playlist.
            // Chaturbate: brand-new token, independent of the player's highest-quality session.
            let url: URL
            if fresh.masterURL.scheme != "data" {
                url = fresh.masterURL
            } else {
                url = fresh.audioPlaylist ?? fresh.videoPlaylist
            }
            return LiveCaptionSource(
                url: url,
                headers: headers,
                userAgent: ua,
                requiresFreshPlaylist: room.platform == .chaturbate
            )
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
        guard let stream else {
            overlayStatus = "等待播放地址…"
            return
        }
        lastIdentity = streamIdentity(for: stream)
        let source = currentSource(room: room, stream: stream)
        let refresh = makeRefresher(room: room)
        Task { await session.start(source: source, refresh: refresh) }
    }

    func handleStreamChanged(room: Room, stream: ResolvedStream?) {
        guard preference.isEnabled, showsCaptions, let stream else { return }
        let identity = streamIdentity(for: stream)
        if lastIdentity == identity { return }
        lastIdentity = identity
        let source = currentSource(room: room, stream: stream)
        let refresh = makeRefresher(room: room)
        Task { await session.retarget(source: source, refresh: refresh) }
    }

    func resumeIfNeeded(room: Room, stream: ResolvedStream?) {
        guard preference.isEnabled else { return }
        showsCaptions = true
        guard let stream else { return }
        lastIdentity = streamIdentity(for: stream)
        let source = currentSource(room: room, stream: stream)
        let refresh = makeRefresher(room: room)
        Task { await session.start(source: source, refresh: refresh) }
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
                if session.phase == .starting || session.phase == .failed {
                    overlayStatus = session.statusMessage
                } else if overlayLine == nil {
                    overlayStatus = session.statusMessage
                } else {
                    overlayStatus = ""
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
