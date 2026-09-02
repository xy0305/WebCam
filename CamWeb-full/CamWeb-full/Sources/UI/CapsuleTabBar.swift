import SwiftUI

struct CapsuleTabBar: View {
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            item(.channels, "频道", "globe")
            item(.favorites, "收藏", "heart.fill")
            item(.library, "配置", "folder.fill")
            item(.settings, "设置", "gearshape.fill")
            item(.search, "搜索", "magnifyingglass")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private func item(_ value: AppTab, _ title: String, _ icon: String) -> some View {
        Button { tab = value } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tab == value ? Color.pink : Color.primary.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
