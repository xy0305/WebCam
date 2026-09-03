import SwiftUI

struct FavoriteView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var appState: AppState
    @ObservedObject private var local = FollowingStore.shared
    @ObservedObject private var special = SpecialFollowStore.shared
    @ObservedObject private var history = WatchHistoryStore.shared
    @State private var remote: [Room] = []
    @State private var loading = false

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    roomSection(
                        title: "非常关注",
                        empty: "播放页点星星加入，优先显示",
                        names: special.usernames
                    )
                    roomSection(
                        title: "最近播放",
                        empty: "看过的主播会出现在这里",
                        names: history.items.map(\.username)
                    )
                    roomSection(
                        title: "收藏",
                        empty: "播放页点爱心即可收藏",
                        names: mergedFollows
                    )
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("收藏")
            .toolbar {
                if !history.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空最近") { history.clear() }
                    }
                }
            }
            .refreshable { await loadRemote() }
            .task { await loadRemote() }
        }
    }

    private var mergedFollows: [String] {
        var out = local.usernames
        for r in remote where !out.contains(r.username) {
            out.append(r.username)
        }
        return out
    }

    @ViewBuilder
    private func roomSection(title: String, empty: String, names: [String], clearHistory: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text("\(names.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
            }
            .padding(.horizontal, 16)

            if names.isEmpty {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(names, id: \.self) { name in
                        Button {
                            appState.openPlayer(username: name, room: room(for: name))
                        } label: {
                            ChannelCard(room: room(for: name))
                                .overlay(alignment: .topLeading) {
                                    if special.contains(name) {
                                        Image(systemName: "star.fill")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.yellow)
                                            .padding(8)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                special.toggle(name)
                            } label: {
                                Label(special.contains(name) ? "取消非常关注" : "非常关注",
                                      systemImage: special.contains(name) ? "star.slash" : "star")
                            }
                            if history.items.contains(where: { $0.username == name }) {
                                Button(role: .destructive) {
                                    history.remove(name)
                                } label: {
                                    Label("从最近播放移除", systemImage: "clock.badge.xmark")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func room(for name: String) -> Room {
        remote.first(where: { $0.username == name }) ?? Room(username: name)
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
