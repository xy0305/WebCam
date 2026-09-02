import SwiftUI
import KSPlayer

@main
struct CamWebApp: App {
    init() {
        URLCache.shared = URLCache(memoryCapacity: 40 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootFlow()
                .environmentObject(AuthManager.shared)
                .environmentObject(AppState.shared)
                .preferredColorScheme(.light)
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

    func acceptAge() {
        acceptedAge = true
        UserDefaults.standard.set(true, forKey: "camweb.age")
    }
}
