import Photos
import UIKit

enum PhotoLibraryExporter {
    enum ExportError: LocalizedError {
        case notVideo
        case denied
        case failed

        var errorDescription: String? {
            switch self {
            case .notVideo: return "还不是可导出的视频文件"
            case .denied: return "没有相册写入权限"
            case .failed: return "导出到相册失败"
            }
        }
    }

    static func saveVideo(_ url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw ExportError.notVideo }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.denied }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    static func hapticStart() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func hapticSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func hapticError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
