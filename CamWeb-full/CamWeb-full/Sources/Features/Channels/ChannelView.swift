import SwiftUI

struct ChannelFilter: Hashable {
    var title: String
    var gender: String
    var keyword: String
}

struct ChannelView: View {
    @EnvironmentObject var appState: AppState
    @State private var path: [ChannelFilter] = []
    @State private var platform: CamPlatform = .chaturbate

    var body: some View {
        NavigationStack(path: $path) {
            ChannelListPage(gender: "", keyword: "", title: "频道", platform: platform)
                .id(platform)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Picker("平台", selection: $platform) {
                            ForEach(CamPlatform.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .navigationDestination(for: ChannelFilter.self) { filter in
                    ChannelListPage(gender: filter.gender, keyword: filter.keyword, title: filter.title, platform: platform)
                }
        }
        .onChange(of: appState.keywordFilter) { _, tag in
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let filter = ChannelFilter(title: appState.groupTitle, gender: "", keyword: t)
            if path.last != filter {
                path.append(filter)
            }
        }
        .onChange(of: path) { _, new in
            if new.isEmpty, !appState.keywordFilter.isEmpty {
                appState.keywordFilter = ""
                appState.groupTitle = "频道"
            }
        }
    }
}

struct ChannelListPage: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var favoriteTags = FavoriteTagsStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let gender: String
    let keyword: String
    let title: String
    var platform: CamPlatform = .chaturbate

    @State private var rooms: [Room] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var offset = 0
    @State private var reachedEnd = false
    @State private var searchText = ""
    @State private var localGender: String = ""
    @State private var requestGeneration = 0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160), spacing: AppTheme.gridSpacing)]
    }

    var filtered: [Room] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rooms }
        return rooms.filter { $0.username.contains(q) || $0.title.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if let errorText, rooms.isEmpty {
                RichEmptyState(
                    icon: "wifi.exclamationmark",
                    title: "加载失败",
                    message: errorText,
                    actionTitle: "重试"
                ) {
                    Task { await reload() }
                }
            } else if rooms.isEmpty && !loading {
                RichEmptyState(
                    icon: "sparkles.tv",
                    title: "这里还空着",
                    message: "换一个分类或平台看看，也可以下拉刷新。",
                    actionTitle: "刷新"
                ) {
                    Task { await reload() }
                }
            } else {
                ScrollView {
                    if gender.isEmpty && keyword.isEmpty && !favoriteTags.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                SectionHeader(title: "收藏标签", systemImage: "star.fill", tint: AppTheme.favorite)
                                Spacer()
                                Text("点击快速切换")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.inkSecondary)
                            }
                            GlowDivider()
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(favoriteTags.tags.enumerated()), id: \.element) { index, tag in
                                        Button { appState.openTag(tag) } label: {
                                            GlassChip(title: "#\(tag)", highlighted: true)
                                        }
                                        .buttonStyle(.plain)
                                        .staggerAppear(index: index)
                                        .contextMenu {
                                            Button(role: .destructive) { favoriteTags.remove(tag) } label: {
                                                Label("取消收藏标签", systemImage: "star.slash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                        .padding(.top, 14)
                    }

                    if loading && rooms.isEmpty {
                        // 骨架屏放在内容流里，避免盖住上方的收藏标签
                        skeletonGrid
                            .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                            .padding(.vertical, 12)
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, room in
                                Button {
                                    appState.openPlayer(username: room.username, room: room)
                                } label: {
                                    ChannelCard(room: room)
                                }
                                .buttonStyle(PressableCardStyle())
                                .staggerAppear(index: index)
                                .onAppear {
                                    if room.id == rooms.last?.id { Task { await loadMore() } }
                                }
                            }
                        }
                        .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                        .padding(.vertical, 12)

                        if loadingMore { ProgressView().tint(AppTheme.accent).padding(.vertical, 16) }
                        if reachedEnd, !filtered.isEmpty {
                            GridEndMark(text: "已经到底了 · 共 \(filtered.count) 个频道")
                        }
                    }
                }
                .refreshable { await reload() }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if platform == .panda {
                        Button("观看人数") { applyGender("") }
                        Button("热门") { applyGender("hot") }
                        Button("最新") { applyGender("new") }
                        Button("NEW BJ") { applyGender("newbj") }
                    } else {
                        Button("全部") { applyGender("") }
                        Button("Women") { applyGender("f") }
                        Button("Couples") { applyGender("c") }
                    }
                } label: {
                    Label(currentSectionTitle, systemImage: "line.3.horizontal.decrease.circle")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索频道")
        .task {
            localGender = gender
            if rooms.isEmpty { await reload() }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(0..<6, id: \.self) { _ in
                SkeletonCard()
            }
        }
    }

    private var currentSectionTitle: String {
        if platform == .panda {
            switch localGender {
            case "hot": return "热门"
            case "new": return "最新"
            case "newbj": return "NEW BJ"
            default: return "观看人数"
            }
        }
        switch localGender {
        case "f": return "Women"
        case "c": return "Couples"
        default: return "全部"
        }
    }

    private func applyGender(_ g: String) {
        guard localGender != g else { return }
        Haptics.selection()
        requestGeneration += 1
        localGender = g
        rooms = []
        offset = 0
        reachedEnd = false
        Task { await reload() }
    }

    private func reload() async {
        let generation = requestGeneration
        let requestedGender = localGender
        loading = true
        errorText = nil
        offset = 0
        reachedEnd = false
        defer { if generation == requestGeneration { loading = false } }
        do {
            let fetched: [Room]
            if platform == .stripchat {
                let primary = requestedGender == "c" ? "couples" : (requestedGender == "m" ? "men" : "girls")
                fetched = try await StripchatAPI.fetch(offset: 0, primary: primary)
            } else if platform == .panda {
                let sort = requestedGender.isEmpty ? "user" : requestedGender
                fetched = try await PandaAPI.fetch(offset: 0, sort: sort)
            } else {
                fetched = try await RoomAPI.fetchRooms(
                    offset: 0,
                    gender: emptyNil(requestedGender),
                    keywords: emptyNil(keyword)
                )
            }
            guard generation == requestGeneration, requestedGender == localGender else { return }
            rooms = fetched
            offset = fetched.count
            reachedEnd = fetched.isEmpty
        } catch {
            guard generation == requestGeneration else { return }
            errorText = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, !reachedEnd, searchText.isEmpty else { return }
        let generation = requestGeneration
        let requestedGender = localGender
        let requestedOffset = offset
        loadingMore = true
        defer { if generation == requestGeneration { loadingMore = false } }
        do {
            let more: [Room]
            if platform == .stripchat {
                let primary = requestedGender == "c" ? "couples" : (requestedGender == "m" ? "men" : "girls")
                more = try await StripchatAPI.fetch(offset: requestedOffset, primary: primary)
            } else if platform == .panda {
                let sort = requestedGender.isEmpty ? "user" : requestedGender
                more = try await PandaAPI.fetch(offset: requestedOffset, sort: sort)
            } else {
                more = try await RoomAPI.fetchRooms(
                    offset: requestedOffset,
                    gender: emptyNil(requestedGender),
                    keywords: emptyNil(keyword)
                )
            }
            guard generation == requestGeneration, requestedGender == localGender else { return }
            if more.isEmpty { reachedEnd = true }
            let exist = Set(rooms.map(\.username))
            rooms.append(contentsOf: more.filter { !exist.contains($0.username) })
            offset = requestedOffset + more.count
        } catch {
        }
    }

    private func emptyNil(_ s: String) -> String? { s.isEmpty ? nil : s }
}
