import SwiftUI
import KSPlayer
import AVFAudio

@main
struct CamWebApp: App {
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
    @Published var groupTitle = "Default"
    @Published var genderFilter = ""
    @Published var miniUsername: String?
    @Published var miniURL: URL?
    @Published var playingUsername: String?

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

    func openPlayer(username: String) {
        stopMini()
        playingUsername = username
    }

    func closePlayer() {
        playingUsername = nil
    }

    func acceptAge() {
        acceptedAge = true
        UserDefaults.standard.set(true, forKey: "camweb.age")
    }
}
