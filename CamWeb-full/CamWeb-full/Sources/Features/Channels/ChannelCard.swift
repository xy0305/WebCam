import SwiftUI

struct ChannelCard: View {
    let room: Room

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: room.thumb) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        ZStack {
                            Color(.secondarySystemBackground)
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    default:
                        ZStack {
                            Color(.secondarySystemBackground)
                            ProgressView().tint(.accentColor)
                        }
                    }
                }
                .frame(height: 148)
                .frame(maxWidth: .infinity)
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
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

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
    }
}
