import SwiftUI

struct ChannelCard: View {
    let room: Room

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: room.thumb) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        ZStack {
                            Color(white: 0.18)
                            Text("温馨提示").font(.headline).foregroundStyle(.orange)
                        }
                    default:
                        ZStack {
                            Color(white: 0.18)
                            ProgressView().tint(.white)
                        }
                    }
                }
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .clipped()

                Text(room.loadState == .timeout ? "超时" : "LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((room.loadState == .timeout ? Color.red : Color.pink).opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
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
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(room.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(room.loadState == .timeout ? Color.gray : Color.red).frame(width: 6, height: 6)
                Text(room.viewersText).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(room.username).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
