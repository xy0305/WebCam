import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var history = SearchHistoryStore.shared
    @State private var query = ""
    @State private var results: [Room] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var editingHistory = false

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if !history.items.isEmpty { historySection }

                    if results.isEmpty && !searching {
                        ContentUnavailableView {
                            Label(errorText == nil ? "搜索主播" : "没有结果",
                                  systemImage: errorText == nil ? "magnifyingglass" : "person.slash")
                        } description: {
                            Text(errorText ?? "输入用户名或关键词，支持精确用户名")
                        }
                        .padding(.top, history.items.isEmpty ? 80 : 24)
                    } else {
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
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "用户名或关键词")
            .onSubmit(of: .search) {
                let q = cleaned(query)
                guard q.count >= 2 else { return }
                history.record(q)
                editingHistory = false
                Task { await search(q) }
            }
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            .overlay { if searching { ProgressView() } }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("搜索历史").font(.headline)
                Spacer()
                if editingHistory {
                    Button("完成") { withAnimation { editingHistory = false } }
                        .font(.subheadline.weight(.semibold))
                }
            }

            SearchHistoryFlow(spacing: 8) {
                ForEach(history.items, id: \.self) { item in
                    HStack(spacing: 6) {
                        Button {
                            guard !editingHistory else { return }
                            query = item
                            history.record(item)
                            Task { await search(item) }
                        } label: {
                            Text(item)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)

                        if editingHistory {
                            Button {
                                withAnimation { history.remove(item) }
                                if history.items.isEmpty { editingHistory = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除 \(item)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.secondary.opacity(0.13), in: Capsule())
                    .contentShape(Capsule())
                    .onLongPressGesture(minimumDuration: 0.45) {
                        withAnimation(.easeInOut(duration: 0.18)) { editingHistory = true }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let q = cleaned(text)
        guard q.count >= 2 else {
            results = []; errorText = nil; searching = false
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
            if rooms.isEmpty { errorText = "没有匹配房间" }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct SearchHistoryFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
