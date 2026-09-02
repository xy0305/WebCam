import SwiftUI

struct FavoriteView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var appState: AppState
    @ObservedObject private var local = FollowingStore.shared
    @State private var remote: [Room] = []
    @State private var loading = false

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                let names = mergedNames
                if names.isEmpty {
                    ContentUnavailableView {
                        Label("暂无收藏", systemImage: "heart")
                    } description: {
                        Text("播放页点爱心即可收藏")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(names, id: \.self) { name in
                                Button {
                                    let room = remote.first(where: { $0.username == name }) ?? Room(username: name)
                                    appState.openPlayer(username: name, room: room)
                                } label: {
                                    ChannelCard(room: remote.first(where: { $0.username == name }) ?? Room(username: name))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .refreshable { await loadRemote() }
                }
            }
            .navigationTitle("收藏")
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
