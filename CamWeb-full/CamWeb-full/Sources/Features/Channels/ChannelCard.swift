import SwiftUI

struct ChannelCard: View {
    let room: Room
    var showFavoriteStar = false
    var isFavorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                thumb
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.62)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 8) {
                            if room.loadState != .timeout {
                                Image(systemName: "waveform")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.42), in: Capsule())
                            }
                            Spacer(minLength: 0)
                            Text(room.tagText)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.5), in: Capsule())
                        }
                        .padding(10)
                    }

                HStack(spacing: 6) {
                    if showFavoriteStar && isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.favorite)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    PulsingLiveBadge(isTimeout: room.loadState == .timeout)
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(room.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(room.loadState == .timeout ? AppTheme.inkSecondary : AppTheme.live)
                        .frame(width: 6, height: 6)
                    Text(room.viewersText)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.inkSecondary)
                    Text("·")
                        .foregroundStyle(AppTheme.inkSecondary.opacity(0.45))
                    Text(room.username)
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }

    private var thumb: some View {
        LinearGradient(
            colors: [AppTheme.card, AppTheme.surface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay {
            AsyncImage(url: room.thumb) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(AppTheme.inkSecondary)
                default:
                    ProgressView().tint(AppTheme.accent)
                }
            }
        }
        .clipped()
    }
}
