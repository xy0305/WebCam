import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var results: [Room] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty && !searching {
                    ContentUnavailableView {
                        Label(errorText == nil ? "搜索主播" : "没有结果",
                              systemImage: errorText == nil ? "magnifyingglass" : "person.slash")
                    } description: {
                        Text(errorText ?? "输入用户名或关键词，支持精确用户名")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(results) { room in
                                Button {
                                    appState.openPlayer(username: room.username, room: room)
                                } label: {
                                    ChannelCard(room: room)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "用户名或关键词")
            .onSubmit(of: .search) { Task { await search(query) } }
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .overlay { if searching { ProgressView() } }
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            results = []
            errorText = nil
            searching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(q)
        }
    }

    private func search(_ q: String) async {
        searching = true
        errorText = nil
        defer { searching = false }
        do {
            let rooms = try await RoomAPI.search(q)
            results = rooms
            if rooms.isEmpty {
                errorText = "没有匹配房间"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
