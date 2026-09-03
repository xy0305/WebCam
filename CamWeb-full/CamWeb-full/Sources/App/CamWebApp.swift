import SwiftUI
import KSPlayer
import AVFAudio

@main
struct CamWebApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        URLCache.shared = URLCache(memoryCapacity: 40 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootFlow()
                .environmentObject(AuthManager.shared)
                .environmentObject(AppState.shared)
        }
    }
}

/// AppDelegate：管理整 App 支持的界面方向，让播放器能真正切换横竖屏
/// 方向由 KSPlayer 的 KSOptions.supportedInterfaceOrientations 统一控制
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return KSOptions.supportedInterfaceOrientations
    }
}

struct RootFlow: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.acceptedAge {
                AgeGateView()
            } else if !auth.isLoggedIn && !auth.continueAsGuest {
                LoginView()
            } else {
                MainShellView()
            }
        }
        .task { await auth.restore() }
    }
}

enum AppTab: Hashable {
    case channels, favorites, library, settings, search
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var acceptedAge: Bool
    @Published var tab: AppTab = .channels
    @Published var groupTitle = "频道"
    @Published var genderFilter = ""
    @Published var keywordFilter = ""
    @Published var miniUsername: String?
    @Published var miniURL: URL?
    @Published var playingUsername: String?
    @Published var playingRoom: Room?
    @Published var playingRecordingURL: URL?

    private init() {
        acceptedAge = UserDefaults.standard.bool(forKey: "camweb.age")
    }

    func startMini(username: String, url: URL) {
        miniUsername = username
        miniURL = url
    }

    func stopMini() {
        miniUsername = nil
        miniURL = nil
    }

    func openPlayer(username: String, room: Room? = nil) {
        stopMini()
        playingRecordingURL = nil
        playingUsername = username
        playingRoom = room ?? Room(username: username)
        WatchHistoryStore.shared.record(username)
    }

    func openRecording(_ url: URL) {
        stopMini()
        playingUsername = nil
        playingRoom = nil
        playingRecordingURL = url
    }

    func closePlayer() {
        playingUsername = nil
        playingRoom = nil
        playingRecordingURL = nil
    }

    func openTag(_ tag: String) {
        let t = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard !t.isEmpty else { return }
        keywordFilter = t
        groupTitle = "#\(t)"
        genderFilter = ""
        closePlayer()
        tab = .channels
    }

    func acceptAge() {
        acceptedAge = true
        UserDefaults.standard.set(true, forKey: "camweb.age")
    }
}
