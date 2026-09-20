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
    @State private var heat: [String: Room] = [:]

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 160), spacing: 14)] }
    private var rooms: [Room] {
        let base: [Room]
        switch selected {
        case .recent: base = history.items.map(\.room)
        case .favorites: base = special.items.map(\.room)
        case .following: base = mergedFollows
        }
        return base.map { room in
            if let live = heat[room.id] { return room.withHeat(live) }
            return room
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
                        Text("\(rooms.count)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    if rooms.isEmpty {
                        ContentUnavailableView(selected.rawValue, systemImage: emptyIcon, description: Text(emptyText))
                            .padding(.top, 52)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(rooms) { room in
                                Button { appState.openPlayer(username: room.username, room: room) } label: {
                                    ChannelCard(room: room)
                                        .overlay(alignment: .topLeading) {
                                            if special.contains(room) {
                                                Image(systemName: "star.fill").font(.caption.weight(.bold))
                                                    .foregroundStyle(.yellow).padding(8)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { roomMenu(room) }
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
            .refreshable { await loadRemote(); await loadHeat() }
            .task { await loadRemote(); await loadHeat() }
            .onChange(of: selected) { _, _ in
                Task { await loadHeat() }
            }
            .onChange(of: history.items) { _, _ in
                if selected == .recent { Task { await loadHeat() } }
            }
        }
    }

    @ViewBuilder private func roomMenu(_ room: Room) -> some View {
        Button { special.toggle(room) } label: {
            Label(special.contains(room) ? "取消收藏" : "收藏", systemImage: special.contains(room) ? "star.slash" : "star")
        }
        if history.items.contains(where: { $0.username == room.username && $0.platform == room.platform }) {
            Button(role: .destructive) { history.remove(room.username) } label: {
                Label("从最近播放移除", systemImage: "clock.badge.xmark")
            }
        }
    }

    private var emptyIcon: String {
        switch selected { case .recent: return "clock"; case .favorites: return "star"; case .following: return "heart" }
    }
    private var mergedFollows: [Room] {
        var out = local.usernames.map { room(for: $0) }
        for room in remote where !out.contains(where: { $0.username == room.username && $0.platform == room.platform }) {
            out.append(room)
        }
        return out
    }
    private func room(for name: String) -> Room {
        remote.first(where: { $0.username == name })
            ?? history.items.first(where: { $0.username == name })?.room
            ?? special.items.first(where: { $0.username == name })?.room
            ?? Room(username: name)
    }
    private func loadRemote() async {
        guard auth.isLoggedIn else { return }
        let rooms = (try? await RoomAPI.fetchFollowed()) ?? []
        remote = rooms
        if !rooms.isEmpty { local.mergeRemote(rooms) }
    }

    private func loadHeat() async {
        let base: [Room]
        switch selected {
        case .recent: base = history.items.map(\.room)
        case .favorites: base = special.items.map(\.room)
        case .following: base = mergedFollows
        }
        guard !base.isEmpty else { return }
        let live = await RoomAPI.refreshHeat(base)
        var next = heat
        for (key, room) in live { next[key] = room }
        heat = next
    }
}
