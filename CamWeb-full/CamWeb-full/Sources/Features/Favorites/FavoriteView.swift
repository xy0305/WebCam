import SwiftUI

struct FavoriteView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var appState: AppState
    @ObservedObject private var local = FollowingStore.shared
    @State private var remote: [Room] = []
    @State private var loading = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("收藏")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                Text(auth.isLoggedIn ? "已登录，尝试同步官网关注" : "未登录，仅显示本机收藏")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                let names = mergedNames
                if names.isEmpty {
                    Text("暂无收藏，播放页点爱心即可收藏").foregroundStyle(.secondary).padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(names, id: \.self) { name in
                                Button {
                                    appState.openPlayer(username: name)
                                } label: {
                                    ChannelCard(room: remote.first(where: { $0.username == name }) ?? Room(username: name))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .refreshable { await loadRemote() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.white)
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadRemote() }
        }
    }

    private var mergedNames: [String] {
        var out = local.usernames
        for r in remote where !out.contains(r.username) {
            out.append(r.username)
        }
        return out
    }

    private func loadRemote() async {
        guard auth.isLoggedIn else { return }
        loading = true
        defer { loading = false }
        let rooms = (try? await RoomAPI.fetchFollowed()) ?? []
        remote = rooms
        if !rooms.isEmpty { local.mergeRemote(rooms) }
    }
}
