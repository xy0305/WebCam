import SwiftUI

struct FavoriteView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case recent = "最近播放"
        case favorites = "收藏"
        case following = "关注"
        var id: Self { self }
    }

    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var appState: AppState
    @ObservedObject private var local = FollowingStore.shared
    @ObservedObject private var special = SpecialFollowStore.shared
    @ObservedObject private var history = WatchHistoryStore.shared
    @State private var remote: [Room] = []
    @State private var selected: Section = .recent

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 160), spacing: 14)] }
    private var names: [String] {
        switch selected {
        case .recent: return history.items.map(\.username)
        case .favorites: return special.usernames
        case .following: return mergedFollows
        }
    }
    private var emptyText: String {
        switch selected {
        case .recent: return "看过的主播会出现在这里"
        case .favorites: return "播放页点星星即可收藏"
        case .following: return "关注主播后会出现在这里"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("分类", selection: $selected) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    HStack {
                        Text(selected.rawValue).font(.title3.weight(.semibold))
                        Text("\(names.count)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    if names.isEmpty {
                        ContentUnavailableView(selected.rawValue, systemImage: emptyIcon, description: Text(emptyText))
                            .padding(.top, 52)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(names, id: \.self) { name in
                                Button { appState.openPlayer(username: name, room: room(for: name)) } label: {
                                    ChannelCard(room: room(for: name))
                                        .overlay(alignment: .topLeading) {
                                            if special.contains(name) {
                                                Image(systemName: "star.fill").font(.caption.weight(.bold))
                                                    .foregroundStyle(.yellow).padding(8)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { roomMenu(name) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("收藏")
            .toolbar {
                if selected == .recent, !history.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { Button("清空最近") { history.clear() } }
                }
            }
            .refreshable { await loadRemote() }
            .task { await loadRemote() }
        }
    }

    @ViewBuilder private func roomMenu(_ name: String) -> some View {
        Button { special.toggle(name) } label: {
            Label(special.contains(name) ? "取消收藏" : "收藏", systemImage: special.contains(name) ? "star.slash" : "star")
        }
        if history.items.contains(where: { $0.username == name }) {
            Button(role: .destructive) { history.remove(name) } label: {
                Label("从最近播放移除", systemImage: "clock.badge.xmark")
            }
        }
    }

    private var emptyIcon: String {
        switch selected { case .recent: return "clock"; case .favorites: return "star"; case .following: return "heart" }
    }
    private var mergedFollows: [String] {
        var out = local.usernames
        for room in remote where !out.contains(room.username) { out.append(room.username) }
        return out
    }
    private func room(for name: String) -> Room { remote.first(where: { $0.username == name }) ?? Room(username: name) }
    private func loadRemote() async {
        guard auth.isLoggedIn else { return }
        let rooms = (try? await RoomAPI.fetchFollowed()) ?? []
        remote = rooms
        if !rooms.isEmpty { local.mergeRemote(rooms) }
    }
}
