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

    @ViewBuilder
    private var tabRoot: some View {
        if #available(iOS 18.0, *) {
            modernTabs
                .overlay(alignment: .bottomTrailing) { miniOverlay }
        } else {
            legacyTabs
                .overlay(alignment: .bottomTrailing) { miniOverlay }
        }
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $appState.tab) {
            Tab("频道", systemImage: "play.rectangle.on.rectangle", value: AppTab.channels) {
                ChannelView()
            }
            Tab("收藏", systemImage: "heart", value: AppTab.favorites) {
                FavoriteView()
            }
            Tab("录像", systemImage: "folder", value: AppTab.library) {
                RecordingsView()
            }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView()
            }
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .modifier(LiquidGlassTabChrome())
    }

    private var legacyTabs: some View {
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
    }

    @ViewBuilder
    private var miniOverlay: some View {
        if appState.miniUsername != nil {
            MiniPlayerView()
                .padding(.trailing, 16)
                .padding(.bottom, 88)
        }
    }
}

private struct LiquidGlassTabChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
