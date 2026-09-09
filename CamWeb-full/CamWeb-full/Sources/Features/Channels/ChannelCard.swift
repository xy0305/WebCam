import SwiftUI

struct ChannelCard: View {
    let room: Room

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Color(.secondarySystemBackground)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: room.thumb) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            case .failure:
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            default:
                                ProgressView().tint(.accentColor)
                            }
                        }
                    }
                    .clipped()

                Text(room.loadState == .timeout ? "超时" : "LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((room.loadState == .timeout ? Color.red : Color.accentColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(room.tagText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(room.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 4) {
                Circle().fill(room.loadState == .timeout ? Color.gray : Color.red).frame(width: 6, height: 6)
                Text(room.viewersText).font(.caption).foregroundStyle(.secondary)
                Text(room.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
