import AVFoundation
import Photos
import UIKit

/// 相册导出：先交由 AVFoundation 重封装，避免 Photos 拒绝中断 HLS 生成的 MP4 时间戳/索引。
enum PhotoLibraryExporter {
    enum ExportError: LocalizedError {
        case notVideo
        case denied
        case incompatible
        case insufficientSpace
        case failed

        var errorDescription: String? {
            switch self {
            case .notVideo: return "还不是可导出的视频文件"
            case .denied: return "没有相册写入权限，请在系统设置中允许“添加照片”权限"
            case .incompatible: return "录像格式无法被系统相册识别，原始恢复录像已保留"
            case .insufficientSpace: return "设备可用空间不足：导出时需要额外空间生成相册兼容副本"
            case .failed: return "保存到相册失败，原始录像已保留"
            }
        }
    }

    static func saveVideo(_ url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw ExportError.notVideo }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.denied }

        let compatible = try await remuxForPhotos(url)
        defer { if compatible != url { try? FileManager.default.removeItem(at: compatible) } }

        do {
            let filename = "\(RecordingStore.exportFileStem(from: url)).mov"
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                request.addResource(with: .video, fileURL: compatible, options: options)
            }
        } catch let error as NSError {
            if error.domain == PHPhotosErrorDomain, error.code == 3302 {
                throw ExportError.incompatible
            }
            if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
                throw ExportError.insufficientSpace
            }
            throw ExportError.failed
        }
    }

    private static func remuxForPhotos(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable), !asset.tracks.isEmpty else {
            throw ExportError.incompatible
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.incompatible
        }

        let stem = RecordingStore.exportFileStem(from: source)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stem).mov")
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()

        guard session.status == .completed,
              FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw ExportError.incompatible
        }
        return output
    }

    static func hapticStart() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func hapticSuccess() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func hapticError() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
