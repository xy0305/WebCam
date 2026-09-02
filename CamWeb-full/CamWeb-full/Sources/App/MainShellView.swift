import SwiftUI

struct MainShellView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch appState.tab {
                case .channels: ChannelView()
                case .favorites: FavoriteView()
                case .library: RecordingsView()
                case .settings: SettingsView()
                case .search: SearchView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 72)
            CapsuleTabBar(tab: $appState.tab)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            if appState.miniUsername != nil {
                HStack {
                    Spacer()
                    MiniPlayerView()
                }
            }
        }
        .background(Color(white: 0.97))
    }
}
