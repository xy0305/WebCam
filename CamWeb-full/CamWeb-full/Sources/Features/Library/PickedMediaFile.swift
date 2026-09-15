import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// PhotosPicker 交付的临时文件；避免把视频整体载入内存。
struct PickedMediaFile: Transferable {
    let url: URL
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMediaFile(url: received.file, filename: received.file.lastPathComponent)
        }
        FileRepresentation(importedContentType: .image) { received in
            PickedMediaFile(url: received.file, filename: received.file.lastPathComponent)
        }
        FileRepresentation(importedContentType: .data) { received in
            PickedMediaFile(url: received.file, filename: received.file.lastPathComponent)
        }
    }
}
