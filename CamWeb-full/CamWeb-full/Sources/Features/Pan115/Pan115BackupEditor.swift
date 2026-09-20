import SwiftUI

struct Pan115BackupEditor: View {
    var existing: Pan115BackupTask?
    var onSave: (Pan115BackupTask) -> Void
    var onCancel: () -> Void

    @State private var task: Pan115BackupTask
    @State private var showDestPicker = false
    @State private var showFilter = false
    @State private var showInterval = false
    @State private var draftFilter = Pan115BackupTask.FilterRule(id: UUID(), kind: .include, match: .suffix, pattern: "")
    @State private var notice: String?

    init(existing: Pan115BackupTask? = nil, onSave: @escaping (Pan115BackupTask) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _task = State(initialValue: existing ?? .blank())
    }

    private var canCreate: Bool {
        let hasSource = task.sourceKind == .photos || !task.sourceBookmark.isEmpty
        return hasSource && task.destinations.contains(where: \.enabled)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sourceSection
                    destSection
                    monitorSection
                    scheduleSection
                    filterSection
                    backupRuleSection
                    advancedSection
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(existing == nil ? "新建备份" : "编辑备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "创建" : "保存") { save() }
                        .disabled(!canCreate)
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showDestPicker) {
                Pan115FolderPicker { cid, name in
                    task.destinations.append(.init(id: UUID(), cid: cid, name: name, enabled: true))
                    showDestPicker = false
                } onCancel: { showDestPicker = false }
            }
            .sheet(isPresented: $showFilter) { filterSheet }
            .confirmationDialog("全量扫描间隔", isPresented: $showInterval, titleVisibility: .visible) {
                Button("从不") { task.fullScanInterval = 0 }
                Button("15 秒") { task.fullScanInterval = 15 }
                Button("1 分钟") { task.fullScanInterval = 60 }
                Button("5 分钟") { task.fullScanInterval = 300 }
                Button("15 分钟") { task.fullScanInterval = 900 }
                Button("1 小时") { task.fullScanInterval = 3600 }
                Button("6 小时") { task.fullScanInterval = 21600 }
                Button("每天") { task.fullScanInterval = 86400 }
                Button("取消", role: .cancel) {}
            }
            .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") { notice = nil }
            } message: { Text(notice ?? "") }
            .onChange(of: task.sourceKind) { _, kind in
                if kind == .photos {
                    task.sourceName = "系统相册"
                    task.sourcePath = "photos"
                    task.sourceBookmark = Data()
                    if task.name == "未命名备份" { task.name = "系统相册" }
                }
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("folder", "来源")
            VStack(spacing: 0) {
                Picker("来源类型", selection: $task.sourceKind) {
                    Text("文件夹").tag(Pan115BackupTask.SourceKind.folder)
                    Text("系统相册").tag(Pan115BackupTask.SourceKind.photos)
                }
                .pickerStyle(.segmented)
                .padding(12)
                Divider()
                if task.sourceKind == .photos {
                    Button {
                        task.sourceName = "系统相册"
                        task.sourcePath = "photos"
                        task.sourceBookmark = Data()
                        task.fsMonitor = true
                        if task.name == "未命名备份" { task.name = "系统相册" }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("源路径").font(.subheadline).foregroundStyle(.secondary)
                                Text("系统相册")
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { pickSource() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("源路径").font(.subheadline).foregroundStyle(.secondary)
                                Text(task.sourceName.isEmpty ? "选择源文件夹..." : task.sourceName)
                                    .foregroundStyle(task.sourceName.isEmpty ? Color.secondary : Color.primary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            caption(task.sourceKind == .photos
                    ? "备份系统相册里的照片和视频。相册有新增时会自动扫描。"
                    : "点进文件夹后勾选任意文件再点「打开」，会备份该文件夹（含子目录）。也可以直接选中文件夹再打开。")
        }
    }

    private var destSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("arrow.right.circle", "目标位置")
            VStack(spacing: 0) {
                if task.destinations.isEmpty {
                    Text("未配置目标位置")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    Divider().padding(.leading, 14)
                } else {
                    ForEach($task.destinations) { $dest in
                        HStack {
                            Toggle(isOn: $dest.enabled) { Text(dest.name).lineLimit(2) }
                            Button(role: .destructive) {
                                task.destinations.removeAll { $0.id == dest.id }
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        }
                        .padding(14)
                        Divider().padding(.leading, 14)
                    }
                }
                Button { showDestPicker = true } label: {
                    Label("添加目标位置", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            caption("文件将备份到所有启用的目标位置。您可以添加多个目标位置以实现冗余。")
        }
    }

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("eye", "监控")
            VStack(spacing: 0) {
                toggleRow("文件系统监控", isOn: $task.fsMonitor)
                Divider().padding(.leading, 14)
                Button { showInterval = true } label: {
                    HStack {
                        Text("全量扫描间隔")
                        Spacer()
                        Text(task.fullScanInterval <= 0 ? "0 秒" : intervalShort)
                            .foregroundStyle(.secondary)
                        Image(systemName: "clock").foregroundStyle(.blue)
                    }
                    .padding(14)
                }
                .buttonStyle(.plain)
                if task.fullScanInterval <= 0 {
                    Text("= 从不").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
                }
                Divider().padding(.leading, 14)
                toggleRow("启动时强制全量扫描", isOn: $task.forceScanOnLaunch)
                Divider().padding(.leading, 14)
                toggleRow("添加后开始扫描", isOn: $task.scanOnCreate)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            caption("文件系统监控：实时监控源文件夹的更改。\n全量扫描间隔：多久执行一次源文件夹的完整扫描以捕获遗漏的更改。\n启动时强制全量扫描：启用后，备份启动时立即执行全量扫描。")
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("calendar", "计划")
            VStack(spacing: 0) {
                toggleRow("启用定时任务", isOn: $task.scheduleEnabled)
                if task.scheduleEnabled {
                    DatePicker(
                        "每天",
                        selection: Binding(
                            get: {
                                Calendar.current.date(from: DateComponents(hour: task.scheduleHour, minute: task.scheduleMinute)) ?? Date()
                            },
                            set: {
                                task.scheduleHour = Calendar.current.component(.hour, from: $0)
                                task.scheduleMinute = Calendar.current.component(.minute, from: $0)
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .padding(14)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            caption("定时任务允许您在特定时间运行全量扫描。这对于在非高峰时段运行备份很有用。")
        }
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("line.3.horizontal.decrease.circle", "文件筛选规则")
            VStack(spacing: 0) {
                Text(task.filters.isEmpty ? "未配置文件规则 - 将备份所有文件" : "已配置 \(task.filters.count) 条规则")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                ForEach(task.filters) { rule in
                    HStack {
                        Text("\(rule.kind.title) · \(rule.match.title) · \(rule.pattern)")
                            .font(.footnote)
                        Spacer()
                        Button(role: .destructive) { task.filters.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                Divider().padding(.leading, 14)
                Button {
                    draftFilter = .init(id: UUID(), kind: .include, match: .suffix, pattern: "")
                    showFilter = true
                } label: {
                    Label("添加规则", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            caption("文件筛选规则控制哪些文件包含在备份中或从备份中排除。\n包含规则（白名单）：只有匹配这些规则的文件才会被备份。\n排除规则（黑名单）：匹配这些规则的文件将被跳过。")
        }
    }

    private var backupRuleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("person", "备份规则")
            VStack(spacing: 0) {
                HStack {
                    Text("文件已存在时")
                    Spacer()
                    Picker("", selection: $task.existPolicy) {
                        ForEach(Pan115BackupTask.ExistPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .padding(14)
                Divider().padding(.leading, 14)
                HStack {
                    Text("源文件删除时")
                    Spacer()
                    Picker("", selection: $task.sourceDeletedPolicy) {
                        ForEach(Pan115BackupTask.SourceDeletedPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .padding(14)
                Divider().padding(.leading, 14)
                HStack {
                    Text("备份完成后")
                    Spacer()
                    Picker("", selection: $task.afterBackup) {
                        ForEach(Pan115BackupTask.AfterBackup.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .padding(14)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            caption("文件已存在时: \(task.existPolicy.detail)\n源文件删除时: \(task.sourceDeletedPolicy.detail)\n备份完成后: \(task.afterBackup.detail)")
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("gearshape.2", "高级")
            VStack(spacing: 0) {
                toggleRow("启用", isOn: $task.enabled)
                Divider().padding(.leading, 14)
                toggleRow("添加后开始扫描", isOn: $task.scanOnCreate)
                Divider().padding(.leading, 14)
                toggleRow("从目标同步删除", isOn: $task.syncDeleteFromDest)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            caption("启用：禁用时，备份任务将不会运行。\n添加后开始扫描：启用后，创建备份后将立即开始全面扫描。\n从目标同步删除：启用后，从目标删除的文件也将从源中删除。请谨慎使用！")
        }
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $draftFilter.kind) {
                    ForEach(Pan115BackupTask.FilterRule.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("匹配", selection: $draftFilter.match) {
                    ForEach(Pan115BackupTask.FilterRule.Match.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("例如 mp4 或 *.mov", text: $draftFilter.pattern)
            }
            .navigationTitle("添加规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showFilter = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        guard !draftFilter.pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        task.filters.append(draftFilter)
                        showFilter = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func pickSource() {
        Pan115FilePicker.presentFolder { url in
            if let info = Pan115BackupStore.shared.bookmark(from: url) {
                task.sourceBookmark = info.data
                task.sourcePath = info.path
                task.sourceName = info.name
                if task.name == "未命名备份" { task.name = info.name }
            } else {
                notice = "无法访问该文件夹，请再选一次"
            }
        }
    }

    private func save() {
        guard canCreate else {
            notice = "请选择源文件夹并至少添加一个目标位置"
            return
        }
        onSave(task)
    }

    private var intervalShort: String {
        let s = Int(task.fullScanInterval)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分钟" }
        if s < 86400 { return "\(s / 3600) 小时" }
        return "\(s / 86400) 天"
    }

    private func label(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).padding(14)
    }
}

struct Pan115FolderPicker: View {
    var onPick: (String, String) -> Void
    var onCancel: () -> Void

    @State private var nodes: [Pan115API.Node] = []
    @State private var path: [(id: String, name: String)] = [("/115", "115")]
    @State private var searchText = ""
    @State private var searchHits: [Pan115API.Node] = []
    @State private var loading = false
    @State private var errorText: String?

    private var cid: String { path.last?.id ?? "/" }
    private var folderName: String { path.map(\.name).joined(separator: " / ") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索文件夹", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("搜索结果") {
                        ForEach(searchHits.filter(\.isDir)) { node in
                            Button {
                                path = [("/115", "115"), (node.id, node.name)]
                                searchText = ""
                                Task { await reload() }
                            } label: { Label(node.name, systemImage: "folder.fill") }
                        }
                    }
                } else {
                    Section(folderName) {
                        if path.count > 1 {
                            Button("上级") { path.removeLast(); Task { await reload() } }
                        }
                        if loading { ProgressView() }
                        if let errorText { Text(errorText).foregroundStyle(.red) }
                        ForEach(nodes.filter(\.isDir)) { node in
                            Button {
                                path.append((node.id, node.name))
                                Task { await reload() }
                            } label: { Label(node.name, systemImage: "folder.fill") }
                        }
                    }
                }
            }
            .navigationTitle("选择 115 文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用此目录") { onPick(cid, folderName) }.fontWeight(.semibold)
                }
            }
            .task { await reload() }
            .onChange(of: searchText) { _, q in
                Task {
                    let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard t.count >= 1 else { searchHits = []; return }
                    searchHits = (try? await Pan115API.search(keyword: t, cid: "/115", foldersOnly: true)) ?? []
                }
            }
        }
    }

    private func reload() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do { nodes = try await Pan115API.listAll(cid: cid) }
        catch { errorText = error.localizedDescription }
    }
}
