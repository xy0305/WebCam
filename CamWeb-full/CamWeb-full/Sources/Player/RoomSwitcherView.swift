import SwiftUI

/// 参考 StripCam 的快速换台面板：当前直播 + 多来源候选房间。
struct RoomSwitcherView: View {
    enum Source: String, CaseIterable, Identifiable {
        case recommended = "推荐"
        case favorites = "收藏"
        case recent = "最近"
        case following = "关注"
        var id: Self { self }
    }

    let current: Room
    let recommended: [Room]
    let favorites: [Room]
    let recent: [Room]
    let following: [Room]
    var onSelect: (Room) -> Void
    var onClose: () -> Void

    @State private var selected: Source = .recommended

    private var rooms: [Room] {
        let sourceRooms: [Room]
        switch selected {
        case .recommended: sourceRooms = recommended
        case .favorites: sourceRooms = favorites
        case .recent: sourceRooms = recent
        case .following: sourceRooms = following
        }
        var seen = Set<String>()
        return sourceRooms.filter { room in
            room.id != current.id && seen.insert(room.id).inserted
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    AsyncImage(url: current.thumb) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                        else { Color.secondary.opacity(0.16).overlay(Image(systemName: "person.fill").foregroundStyle(.secondary)) }
                    }
                    .frame(width: 42, height: 42).clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.username).font(.headline).lineLimit(1)
                        Label(current.platform.title, systemImage: "play.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.subheadline.weight(.bold))
                            .frame(width: 36, height: 36).background(.thinMaterial, in: Circle())
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)

                Picker("换台来源", selection: $selected) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 12)

                if rooms.isEmpty {
                    ContentUnavailableView("暂无可切换直播间", systemImage: "rectangle.3.group", description: Text("此分类里还没有其他主播"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 16) {
                            ForEach(rooms) { room in
                                Button { onSelect(room) } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        AsyncImage(url: room.thumb) { phase in
                                            if case .success(let image) = phase { image.resizable().scaledToFill() }
                                            else { Color.secondary.opacity(0.15).overlay(Image(systemName: "play.fill").foregroundStyle(.secondary)) }
                                        }
                                        .frame(height: 112).frame(maxWidth: .infinity).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                        Text(room.username).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                        Text("\(room.platform.title) · \(room.viewersText)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("快速换台")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
