import SwiftUI

struct ChannelView: View {
    @EnvironmentObject var appState: AppState
    @State private var rooms: [Room] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var offset = 0
    @State private var reachedEnd = false
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var filtered: [Room] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rooms }
        return rooms.filter { $0.username.contains(q) || $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
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
                        LazyVGrid(columns: columns, spacing: 14) {
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        if loadingMore { ProgressView().padding(.vertical, 16) }
                    }
                    .refreshable { await reload() }
                }
            }
            .navigationTitle(isFiltered ? appState.groupTitle : "频道")
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if isFiltered {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            clearFilter()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("全部频道") { applyFilter("", title: "频道") }
                        Button("Female") { applyFilter("f", title: "女主播") }
                        Button("Male") { applyFilter("m", title: "男主播") }
                        Button("Couple") { applyFilter("c", title: "情侣") }
                        Button("Trans") { applyFilter("t", title: "Trans") }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .edgeSwipeBack(enabled: isFiltered) {
                clearFilter()
            }
            .searchable(text: $searchText, prompt: "搜索频道")
            .task { if rooms.isEmpty { await reload() } }
            .onChange(of: appState.keywordFilter) { _, _ in
                Task { await reload() }
            }
            .overlay { if loading && rooms.isEmpty { ProgressView() } }
        }
    }

    private var isFiltered: Bool {
        !appState.keywordFilter.isEmpty || !appState.genderFilter.isEmpty
    }

    private func clearFilter() {
        applyFilter("", title: "频道")
    }

    private func applyFilter(_ gender: String, title: String) {
        appState.genderFilter = gender
        appState.keywordFilter = ""
        appState.groupTitle = title
        Task { await reload() }
    }

    private func reload() async {
        loading = true
        errorText = nil
        offset = 0
        reachedEnd = false
        defer { loading = false }
        do {
            rooms = try await RoomAPI.fetchRooms(
                offset: 0,
                gender: emptyNil(appState.genderFilter),
                keywords: emptyNil(appState.keywordFilter)
            )
            offset = rooms.count
            reachedEnd = rooms.isEmpty
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, !reachedEnd, searchText.isEmpty else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let more = try await RoomAPI.fetchRooms(
                offset: offset,
                gender: emptyNil(appState.genderFilter),
                keywords: emptyNil(appState.keywordFilter)
            )
            if more.isEmpty { reachedEnd = true }
            let exist = Set(rooms.map(\.username))
            rooms.append(contentsOf: more.filter { !exist.contains($0.username) })
            offset = rooms.count
        } catch {
        }
    }

    private func emptyNil(_ s: String) -> String? { s.isEmpty ? nil : s }
}
