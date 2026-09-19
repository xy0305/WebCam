import SwiftUI

/// 对照 OpenList / 115driver 回收站：列表、还原、清空。
struct Pan115RecycleView: View {
    @State private var items: [Pan115API.RecycleItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                if loading && items.isEmpty { ProgressView() }
                if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
                if items.isEmpty, !loading {
                    Text("回收站是空的").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Label {
                        VStack(alignment: .leading) {
                            Text(item.name).lineLimit(1)
                            Text(byteText(item.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: item.isDir ? "folder.fill" : "doc.fill")
                    }
                    .swipeActions {
                        Button("还原") { Task { await revert([item.id]) } }.tint(.blue)
                    }
                }
            }
            if !items.isEmpty {
                Section {
                    Button("清空回收站", role: .destructive) {
                        Task { await clean() }
                    }
                }
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func reload() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do { items = try await Pan115API.recycleList() }
        catch { errorText = error.localizedDescription }
    }

    private func revert(_ ids: [String]) async {
        do {
            try await Pan115API.recycleRevert(ids: ids)
            await reload()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func clean() async {
        do {
            try await Pan115API.recycleClean()
            await reload()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func byteText(_ n: Int64) -> String {
        if n >= 1_073_741_824 { return String(format: "%.2f GB", Double(n) / 1_073_741_824) }
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }
}
