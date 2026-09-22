import SwiftUI

struct ChannelCard: View {
    let room: Room
    var showFavoriteStar = false
    var isFavorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
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
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
                .clipped()

                HStack(spacing: 6) {
                    if showFavoriteStar && isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.favorite)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .scaleEffect(1.05)
                            .shadow(color: AppTheme.favorite.opacity(0.55), radius: 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                    PulsingLiveBadge(isTimeout: room.loadState == .timeout)
                }
                .padding(8)
                .animation(AppMotion.spring, value: isFavorite)

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        EqualizerBars(tint: .white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.4), in: Capsule())
                        Spacer()
                        Text(room.tagText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color(hex: 0xE8F0F8).opacity(0.25), .clear, Color(hex: 0x1A2433).opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color(hex: 0x8FBCD4).opacity(0.08), radius: 12, y: 5)

            Text(room.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)

            HStack(spacing: 5) {
                Circle()
                    .fill(room.loadState == .timeout ? AppTheme.inkSecondary : AppTheme.live)
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: (room.loadState == .timeout ? Color.clear : AppTheme.live).opacity(0.7),
                        radius: 3
                    )
                    .scaleEffect(room.loadState == .timeout ? 1 : 1.15)
                    .animation(
                        room.loadState == .timeout ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: room.loadState
                    )
                Text(room.viewersText)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.inkSecondary)
                Text("·").foregroundStyle(AppTheme.inkSecondary.opacity(0.5))
                Text(room.username)
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
