import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var results: [Room] = []
    @State private var searching = false
    @State private var errorText: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("搜索")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("用户名或关键词", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if searching { ProgressView() }
                }
                .padding(12)
                .background(Color(white: 0.93), in: Capsule())
                .padding(.horizontal, 16)

                if let name = sanitized {
                    Button {
                        appState.openPlayer(username: name)
                    } label: {
                        Text("直接播放 \(name)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.pink, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                }

                if let errorText {
                    Text(errorText).foregroundStyle(.red).padding(.horizontal, 16)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(results) { room in
                            Button {
                                appState.openPlayer(username: room.username)
                            } label: {
                                ChannelCard(room: room)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .background(Color.white)
            .toolbar(.hidden, for: .navigationBar)
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
