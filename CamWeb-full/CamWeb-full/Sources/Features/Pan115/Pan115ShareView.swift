import SwiftUI

/// 对照 OpenList 115_share：打开分享、浏览、转存到自己的目录。
struct Pan115ShareView: View {
    @State private var raw = ""
    @State private var receive = ""
    @State private var code = ""
    @State private var nodes: [Pan115API.Node] = []
    @State private var path: [(id: String, name: String)] = [("0", "分享")]
    @State private var loading = false
    @State private var errorText: String?
    @State private var notice: String?
    @State private var showFolder = false
    @State private var pendingIDs: [String] = []
    @State private var destName = ""

    private var cid: String { path.last?.id ?? "0" }

    var body: some View {
        List {
            Section {
                TextField("分享链接或分享码", text: $raw)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("提取码（没有可空）", text: $receive)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("打开分享") { Task { await open() } }
            }

            if !code.isEmpty {
                Section(path.map(\.name).joined(separator: " / ")) {
                    if path.count > 1 {
                        Button("上级") {
                            path.removeLast()
                            Task { await load() }
                        }
                    }
                    if loading { ProgressView() }
                    if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
                    ForEach(nodes.filter(\.isDir)) { node in
                        Button {
                            path.append((node.id, node.name))
                            Task { await load() }
                        } label: {
                            Label(node.name, systemImage: "folder.fill")
                        }
                    }
                    ForEach(nodes.filter { !$0.isDir }) { node in
                        Label(node.name, systemImage: "doc.fill")
                    }
                    Button("转存当前目录全部") {
                        pendingIDs = nodes.map(\.id)
                        showFolder = true
                    }
                    .disabled(nodes.isEmpty)
                }
            }
        }
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(isPresented: $showFolder) {
            Pan115FolderPicker { dest, name in
                destName = name
                showFolder = false
                Task { await receiveTo(dest) }
            } onCancel: {
                showFolder = false
            }
        }
    }

    private func open() async {
        let parsed = Pan115API.parseShare(raw)
        code = parsed.code
        if receive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receive = parsed.receive
        }
        path = [("0", "分享")]
        await load()
    }

    private func load() async {
        guard !code.isEmpty else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            nodes = try await Pan115API.shareSnap(code: code, receive: receive, cid: cid)
        } catch {
            errorText = error.localizedDescription
            nodes = []
        }
    }

    private func receiveTo(_ dest: String) async {
        do {
            try await Pan115API.shareReceive(code: code, receive: receive, fileIDs: pendingIDs, destCID: dest)
            notice = "已转存到 \(destName)"
        } catch {
            notice = error.localizedDescription
        }
    }
}
