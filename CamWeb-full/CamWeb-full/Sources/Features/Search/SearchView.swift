import SwiftUI
import UIKit

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
    @State private var pasteText = ""
    @State private var pasteError: String?
    @State private var editingPastes = false
    @ObservedObject private var pasted = PastedURLStore.shared
    @FocusState private var searchFocused: Bool
    @FocusState private var pasteFocused: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160), spacing: AppTheme.gridSpacing)]
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
                        openURLSection

                        if !history.items.isEmpty { historySection }

                        if results.isEmpty && !searching && pasteError == nil {
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
                                        Haptics.tap()
                                        appState.openPlayer(username: room.username, room: room)
                                    } label: {
                                        ChannelCard(room: room)
                                    }
                                    .buttonStyle(SoftPress())
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
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
            .overlay { if searching { ProgressView().tint(AppTheme.accent) } }
        }
        .brandScreen()
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(AppTheme.inkSecondary)

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
                        .foregroundStyle(AppTheme.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .liquidGlass(corner: 16, strong: searchFocused)
        .softGlow(searchFocused)
        .animation(AppMotion.soft, value: searchFocused)
    }

    private var openURLSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "打开地址", systemImage: "link", tint: AppTheme.accent)

            HStack(spacing: 10) {
                TextField("粘贴 RTMP / HLS / http(s) 地址", text: $pasteText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(2...4)
                    .focused($pasteFocused)
                    .submitLabel(.go)
                    .onSubmit { openPasted() }

                Button {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        pasteText = clip
                        Haptics.tap()
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.inkSecondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从剪贴板粘贴")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liquidGlass(corner: 16, strong: pasteFocused)

            HStack(spacing: 10) {
                Button {
                    openPasted()
                } label: {
                    Text("播放")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)

                if !pasted.items.isEmpty {
                    Button {
                        withAnimation { editingPastes.toggle() }
                    } label: {
                        Image(systemName: editingPastes ? "checkmark" : "trash")
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(editingPastes ? "完成编辑" : "编辑最近地址")
                }
            }

            if let pasteError {
                Text(pasteError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("支持 rtmp://、rtmps://、http(s) .m3u8 及普通媒体地址。只播放粘贴的地址，不会抓取房间列表。插件最高画质不受影响。")
                .font(.caption2)
                .foregroundStyle(AppTheme.inkSecondary)

            if !pasted.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近打开")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.inkSecondary)
                    ForEach(pasted.items, id: \.self) { item in
                        HStack(spacing: 8) {
                            Button {
                                guard !editingPastes else { return }
                                pasteText = item
                                openPasted(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let u = DirectStreamURL.parse(item) {
                                        Text(DirectStreamURL.displayTitle(u))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(AppTheme.ink)
                                        Text("\(DirectStreamURL.schemeLabel(u)) · \(item)")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.inkSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    } else {
                                        Text(item)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            if editingPastes {
                                Button {
                                    withAnimation { pasted.remove(item) }
                                    if pasted.items.isEmpty { editingPastes = false }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(AppTheme.inkSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .liquidGlass(corner: 12, strong: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openPasted(_ raw: String? = nil) {
        let value = raw ?? pasteText
        pasteFocused = false
        searchFocused = false
        guard let url = DirectStreamURL.parse(value) else {
            pasteError = "地址无效：请使用 rtmp://、rtmps:// 或 http(s)://"
            return
        }
        pasteError = nil
        pasteText = DirectStreamURL.normalize(value)
        Haptics.tap()
        appState.openDirectURL(url)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SectionHeader(title: "搜索历史", systemImage: "clock.arrow.circlepath", tint: AppTheme.inkSecondary)
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
                            .foregroundStyle(AppTheme.inkSecondary)
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
                Haptics.tap()
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
            .buttonStyle(SoftPress())

            if editingHistory {
                Button {
                    Haptics.tap()
                    withAnimation { history.remove(item) }
                    if history.items.isEmpty { editingHistory = false; historyExpanded = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.inkSecondary)
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel("删除 \(item)")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 36)
        .glassChip()
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
            async let chaturbate = RoomAPI.search(value)
            async let stripchat = StripchatAPI.search(value)
            async let panda = PandaAPI.search(value)
            let cb = (try? await chaturbate) ?? []
            let sc = (try? await stripchat) ?? []
            let pd = (try? await panda) ?? []
            var seen = Set<String>()
            var rooms: [Room] = []
            for room in sc + pd + cb where seen.insert(room.id).inserted {
                rooms.append(room)
            }
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
