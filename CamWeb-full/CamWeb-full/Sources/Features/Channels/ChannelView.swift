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
        [GridItem(.adaptive(minimum: 160), spacing: 14)]
    }

    var filtered: [Room] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rooms }
        return rooms.filter { $0.username.contains(q) || $0.title.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if let errorText, rooms.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorText)
                } actions: {
                    Button("重试") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    if gender.isEmpty && keyword.isEmpty && !favoriteTags.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Label("收藏标签", systemImage: "star.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.yellow)
                                Spacer()
                                Text("点击快速切换")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(favoriteTags.tags, id: \.self) { tag in
                                        Button { appState.openTag(tag) } label: {
                                            Text("#\(tag)")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(.thinMaterial, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
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

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { room in
                            Button {
                                appState.openPlayer(username: room.username, room: room)
                            } label: {
                                ChannelCard(room: room)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if room.id == rooms.last?.id { Task { await loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                    .padding(.vertical, 12)

                    if loadingMore { ProgressView().padding(.vertical, 16) }
                }
                .refreshable { await reload() }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部") { applyGender("") }
                    Button("Women") { applyGender("f") }
                    Button("Couples") { applyGender("c") }
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
        .overlay { if loading && rooms.isEmpty { ProgressView() } }
    }

    private var currentSectionTitle: String {
        switch localGender {
        case "f": return "Women"
        case "c": return "Couples"
        default: return "全部"
        }
    }

    private func applyGender(_ g: String) {
        guard localGender != g else { return }
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
