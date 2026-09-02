import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var results: [Room] = []
    @State private var searching = false
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty && !searching {
                    ContentUnavailableView {
                        Label("搜索主播", systemImage: "magnifyingglass")
                    } description: {
                        Text("输入用户名或关键词搜直播房间")
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
            .onSubmit(of: .search) { Task { await search() } }
            .overlay { if searching { ProgressView() } }
            .toolbar {
                if let name = sanitized {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("播放 \(name)") {
                            appState.openPlayer(username: name, room: Room(username: name))
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private var sanitized: String? {
        let s = query.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return s.count >= 2 ? s : nil
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searching = true
        errorText = nil
        defer { searching = false }
        do {
            results = try await RoomAPI.fetchRooms(keywords: q)
            if results.isEmpty { errorText = "没有匹配房间，仍可直接播放用户名" }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
