import SwiftUI

struct MainShellView: View {
    @EnvironmentObject var appState: AppState

    private var isCoverPresented: Bool {
        appState.playingUsername != nil || appState.playingRecordingURL != nil || appState.playing115URL != nil || appState.playing115ImageURL != nil
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
                .id(name)
                .environmentObject(appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        } else if let url = appState.playingRecordingURL {
            RecordingPlayerView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        } else if let url = appState.playing115URL {
            Pan115PlayerView(url: url, title: appState.playing115Title)
                .id(url.absoluteString)
                .environmentObject(appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        } else if let url = appState.playing115ImageURL {
            Pan115ImagePreview(url: url, title: appState.playing115Title)
                .id(url.absoluteString)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
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
            Tab("115", systemImage: "externaldrive", value: AppTab.pan115) {
                Pan115View()
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
            Pan115View()
                .tabItem { Label("115", systemImage: "externaldrive") }
                .tag(AppTab.pan115)
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
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), sizeClass != .regular {
            content
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            // iPad 使用底部 Tab，铺满全屏，不要变成侧边栏分栏。
            content
        }
    }
}
