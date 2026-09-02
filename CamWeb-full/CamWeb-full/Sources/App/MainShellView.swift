import SwiftUI

struct MainShellView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
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

            // 应用内悬浮小窗（非系统 PiP）
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
        .fullScreenCover(isPresented: Binding(
            get: { appState.playingUsername != nil },
            set: { if !$0 { appState.closePlayer() } }
        )) {
            if let name = appState.playingUsername {
                PlayerView(username: name, room: appState.playingRoom)
                    .environmentObject(appState)
            }
        }
    }
}
