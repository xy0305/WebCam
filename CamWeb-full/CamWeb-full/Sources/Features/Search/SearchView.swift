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
    @State private var historyExpanded = false
    @FocusState private var searchFocused: Bool

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 220 : 150), spacing: 12)]
    }
    private var visibleHistory: [String] {
        editingHistory || historyExpanded ? history.items : Array(history.items.prefix(5))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

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
                            .padding(.top, history.items.isEmpty ? 72 : 20)
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(results) { room in
                                    Button {
                                        searchFocused = false
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
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
            .overlay { if searching { ProgressView() } }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("用户名或关键词", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { submitSearch() }
                .onChange(of: query) { _, value in scheduleSearch(value) }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    errorText = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.secondary.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text("搜索历史")
                    .font(.title3.weight(.semibold))
                Spacer()
                if editingHistory {
                    Button("全部删除", role: .destructive) {
                        withAnimation { history.clear(); editingHistory = false; historyExpanded = false }
                    }
                    Divider().frame(height: 18)
                    Button("完成") { withAnimation { editingHistory = false } }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { editingHistory = true; historyExpanded = true }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑搜索历史")
                }
            }

            SearchHistoryFlow(spacing: 9) {
                ForEach(visibleHistory, id: \.self) { item in
                    historyChip(item)
                }

                if !editingHistory, history.items.count > 5 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { historyExpanded.toggle() }
                    } label: {
                        Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.secondary.opacity(0.08), in: Circle())
                            .overlay(Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyChip(_ item: String) -> some View {
        HStack(spacing: 6) {
            Button {
                guard !editingHistory else { return }
                query = item
                history.record(item)
                searchFocused = false
                Task { await search(item) }
            } label: {
                Text(item)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: 210)
            }
            .buttonStyle(.plain)

            if editingHistory {
                Button {
                    withAnimation { history.remove(item) }
                    if history.items.isEmpty { editingHistory = false; historyExpanded = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除 \(item)")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 36)
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.16), lineWidth: 0.7))
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: 0.45) {
            withAnimation(.easeInOut(duration: 0.18)) { editingHistory = true; historyExpanded = true }
        }
    }

    private func submitSearch() {
        let value = cleaned(query)
        guard value.count >= 2 else { return }
        history.record(value)
        editingHistory = false
        searchFocused = false
        Task { await search(value) }
    }

    private func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let value = cleaned(text)
        guard value.count >= 2 else {
            results = []; errorText = nil; searching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(value)
        }
    }

    private func search(_ value: String) async {
        searching = true
        errorText = nil
        defer { searching = false }
        do {
            let rooms = try await RoomAPI.search(value)
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
