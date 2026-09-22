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
    @State private var syncing = false
    @State private var syncMessage: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 160), spacing: AppTheme.gridSpacing)] }
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
                        SectionHeader(title: selected.rawValue, systemImage: emptyIcon, tint: sectionTint, trailing: "\(rooms.count)")
                        GlowDivider().frame(width: 40).padding(.leading, 8)
                    }
                    .padding(.horizontal, 16)
                    .animation(AppMotion.spring, value: selected)

                    if rooms.isEmpty {
                        RichEmptyState(
                            icon: emptyIcon,
                            title: selected.rawValue,
                            message: emptyText,
                            actionTitle: selected == .following ? "去频道看看" : nil
                        ) {
                            Haptics.tap()
                            appState.tab = .channels
                        }
                        .padding(.top, 24)
                        .transition(.opacity)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
                                Button { appState.openPlayer(username: room.username, room: room) } label: {
                                    ChannelCard(
                                        room: room,
                                        showFavoriteStar: true,
                                        isFavorite: special.contains(room)
                                    )
                                }
                                .buttonStyle(SoftPress())
                                .staggerAppear(index: index, enabled: index < 8)
                                .contextMenu { roomMenu(room) }
                            }
                        }
                        .padding(.horizontal, 16)
                        if rooms.count >= 6 {
                            GridEndMark(text: "共 \(rooms.count) 条")
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("收藏")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await syncCloudNow() }
                    } label: {
                        if syncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("立即同步", systemImage: "icloud.and.arrow.down")
                        }
                    }
                    .disabled(syncing)
                }
                if selected == .recent, !history.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { Button("清空最近") { history.clear() } }
                }
            }
            .refreshable { await loadRemote(); await loadHeat() }
            .task { await loadRemote(); await loadHeat() }
            .onChange(of: selected) { _, _ in
                Haptics.selection()
                Task { await loadHeat() }
            }
            .onChange(of: history.items) { _, _ in
                if selected == .recent { Task { await loadHeat() } }
            }
        }
        .toastHost()
    }

    @ViewBuilder private func roomMenu(_ room: Room) -> some View {
        Button {
            Haptics.selection()
            special.toggle(room)
            ToastCenter.shared.show(special.contains(room) ? "已收藏 \(room.username)" : "已取消收藏")
        } label: {
            Label(special.contains(room) ? "取消收藏" : "收藏", systemImage: special.contains(room) ? "star.slash" : "star")
        }
        if history.items.contains(where: { $0.username == room.username && $0.platform == room.platform }) {
            Button(role: .destructive) {
                Haptics.warning()
                history.remove(room.username)
                ToastCenter.shared.show("已从最近播放移除")
            } label: {
                Label("从最近播放移除", systemImage: "clock.badge.xmark")
            }
        }
    }

    private var emptyIcon: String {
        switch selected { case .recent: return "clock"; case .favorites: return "star"; case .following: return "heart" }
    }

    private var sectionTint: Color {
        switch selected {
        case .recent: return AppTheme.inkSecondary
        case .favorites: return AppTheme.favorite
        case .following: return AppTheme.accent
        }
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

    private func syncCloudNow() async {
        syncing = true
        let followOK = local.syncNow()
        let favoriteOK = special.syncNow()
        let tagsOK = FavoriteTagsStore.shared.syncNow()
        let nutstoreOK = await NutstoreSyncCoordinator.syncAll(showMessage: false)
        await loadRemote()
        await loadHeat()
        syncing = false
        if nutstoreOK {
            syncMessage = "已通过坚果云合并收藏、关注和标签"
        } else if NutstoreSession.shared.isConfigured {
            syncMessage = followOK && favoriteOK && tagsOK
                ? "已从 iCloud 合并；坚果云同步失败：\(NutstoreSession.shared.lastMessage ?? "请检查网络")"
                : "同步失败，请检查坚果云与 iCloud 配置"
        } else {
            syncMessage = (followOK && favoriteOK && tagsOK)
                ? "已从 iCloud 合并收藏、关注和标签。证书不同时请到设置配置坚果云"
                : "iCloud 暂时无法同步。证书不同时请到设置配置坚果云"
        }
        if let syncMessage {
            ToastCenter.shared.show(syncMessage, success: nutstoreOK || followOK || favoriteOK || tagsOK)
        }
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
