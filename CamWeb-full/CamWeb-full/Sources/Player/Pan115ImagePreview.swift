import SwiftUI
import UIKit

/// 115 网盘图片：Cookie 直链，全屏查看。
struct Pan115ImagePreview: View {
    let url: URL
    let title: String
    @Environment(\.nativeDismiss) private var nativeDismiss
    @State private var image: UIImage?
    @State private var errorText: String?
    @State private var loading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else if loading {
                ProgressView().tint(.white)
            } else {
                Text(errorText ?? "打不开这张图")
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
            }

            VStack {
                HStack(spacing: 12) {
                    Button { nativeDismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 54)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 40
        Pan115API.fileHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                errorText = "HTTP \(http.statusCode)"
                return
            }
            guard let img = UIImage(data: data) else {
                errorText = "不是可显示的图片"
                return
            }
            image = img
        } catch {
            errorText = error.localizedDescription
        }
    }
}
