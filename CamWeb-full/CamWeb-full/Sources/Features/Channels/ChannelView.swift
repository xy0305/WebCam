import SwiftUI

struct ChannelView: View {
    @EnvironmentObject var appState: AppState
    @State private var rooms: [Room] = []
    @State private var query = ""
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var offset = 0
    @State private var reachedEnd = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var filtered: [Room] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rooms }
        return rooms.filter { $0.username.contains(q) || $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text(appState.groupTitle)
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 16)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索", text: $query)
                }
                .padding(12)
                .background(Color(white: 0.93), in: Capsule())
                .padding(.horizontal, 16)

                if let errorText, rooms.isEmpty {
                    Text(errorText).foregroundStyle(.secondary).padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filtered) { room in
                                NavigationLink(value: room.username) {
                                    ChannelCard(room: room)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if room.id == rooms.last?.id { Task { await loadMore() } }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        if loadingMore { ProgressView().padding(.bottom, 20) }
                    }
                    .refreshable { await reload() }
                }
            }
            .background(Color.white)
            .toolbar(.hidden, for: .navigationBar)
            .task { if rooms.isEmpty { await reload() } }
            .overlay { if loading && rooms.isEmpty { ProgressView() } }
            .navigationDestination(for: String.self) { PlayerView(username: $0) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Button("全部频道") { applyFilter("", title: "Default") }
                Button("Female") { applyFilter("f", title: "Female") }
                Button("Male") { applyFilter("m", title: "Male") }
                Button("Couple") { applyFilter("c", title: "Couple") }
                Button("Trans") { applyFilter("t", title: "Trans") }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill")
                    Text(appState.genderFilter.isEmpty ? "全部频道" : appState.groupTitle)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.94), in: Capsule())
            }
            Spacer()
            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 40, height: 36)
                    .background(Color(white: 0.94), in: Capsule())
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func applyFilter(_ gender: String, title: String) {
        appState.genderFilter = gender
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
            rooms = try await RoomAPI.fetchRooms(offset: 0, gender: emptyNil(appState.genderFilter))
            offset = rooms.count
            reachedEnd = rooms.isEmpty
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, !reachedEnd, query.isEmpty else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let more = try await RoomAPI.fetchRooms(offset: offset, gender: emptyNil(appState.genderFilter))
            if more.isEmpty { reachedEnd = true }
            let exist = Set(rooms.map(\.username))
            rooms.append(contentsOf: more.filter { !exist.contains($0.username) })
            offset = rooms.count
        } catch {
        }
    }

    private func emptyNil(_ s: String) -> String? { s.isEmpty ? nil : s }
}
