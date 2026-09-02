import SwiftUI

struct MainShellView: View {
    @EnvironmentObject var appState: AppState

    private var isCoverPresented: Bool {
        appState.playingUsername != nil || appState.playingRecordingURL != nil
    }

    var body: some View {
        NativeSwipeStack(
            isPresented: Binding(
                get: { isCoverPresented },
                set: { if !$0 { appState.closePlayer() } }
            ),
            root: { tabRoot },
            cover: { coverPage }
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var coverPage: some View {
        if let name = appState.playingUsername {
            PlayerView(username: name, room: appState.playingRoom)
                .environmentObject(appState)
        } else if let url = appState.playingRecordingURL {
            RecordingPlayerView(url: url)
        }
    }

    private var tabRoot: some View {
        ZStack {
            TabView(selection: $appState.tab) {
                ChannelView()
                    .tabItem { Label("频道", systemImage: "play.rectangle.on.rectangle") }
                    .tag(AppTab.channels)

                FavoriteView()
                    .tabItem { Label("收藏", systemImage: "heart") }
                    .tag(AppTab.favorites)

                RecordingsView()
                    .tabItem { Label("录像", systemImage: "folder") }
                    .tag(AppTab.library)

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)

                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }

            if appState.miniUsername != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        MiniPlayerView()
                    }
                }
            }
        }
    }
}
