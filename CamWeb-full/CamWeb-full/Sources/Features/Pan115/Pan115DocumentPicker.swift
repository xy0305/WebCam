import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 直接 present 系统文件选择器。包进 SwiftUI sheet 时点「打开」经常没回调。
enum Pan115FilePicker {
    static func present(onPicked: @escaping ([URL]) -> Void) {
        // asCopy: true 会在回调前把全部选中文件拷进 App，多选大文件会卡死、占十几 G。
        present(types: [.item, .content, .data, .folder, .directory, .movie, .video, .image, .audio], asCopy: false, multiple: true) { onPicked($0) }
    }

    /// 文件夹选择：点进目录后文件不再灰掉。选中文件则用它所在文件夹；选中文件夹则用该文件夹。
    static func presentFolder(onPicked: @escaping (URL) -> Void) {
        present(types: [.folder, .directory, .item], asCopy: false, multiple: true) { urls in
            guard let folder = folderURL(from: urls) else { return }
            onPicked(folder)
        }
    }

    private static func folderURL(from urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        let access = first.startAccessingSecurityScopedResource()
        defer { if access { first.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        if urls.count == 1 && isDir.boolValue { return first }
        return first.deletingLastPathComponent()
    }

    private static func present(types: [UTType], asCopy: Bool, multiple: Bool, onPicked: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        picker.shouldShowFileExtensions = true
        let holder = Holder(onPicked: onPicked)
        picker.delegate = holder
        objc_setAssociatedObject(picker, &Holder.key, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard let host = topController() else { return }
        host.present(picker, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Holder: NSObject, UIDocumentPickerDelegate {
        static var key: UInt8 = 0
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

enum Pan115Inbox {
    struct Planned: Sendable {
        let source: URL
        let name: String
        let size: Int64
        let bookmark: Data?
    }

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("115Inbox", isDirectory: true)
    }

    /// 只列文件、做书签，不拷贝。拷贝放到真正开始上传时。
    static func plan(_ urls: [URL]) -> [Planned] {
        var out: [Planned] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            out.append(contentsOf: listTree(url))
        }
        return out
    }

    static func uniqueURL(_ raw: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = uniqueName(raw)
        return directory.appendingPathComponent(name)
    }

    static func copyFile(from src: URL, to dest: URL) throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            try streamCopy(from: src, to: dest)
        }
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    static func sweep(keeping urls: [URL]) {
        let keep = Set(urls.map(\.standardizedFileURL.path))
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where !keep.contains(file.standardizedFileURL.path) {
                try? fm.removeItem(at: file)
            }
        }
        if let left = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), left.isEmpty {
            try? fm.removeItem(at: directory)
        }
        let tmp = fm.temporaryDirectory
        if let temps = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for file in temps where file.lastPathComponent.hasPrefix("115-") && file.pathExtension == "form" {
                if !keep.contains(file.standardizedFileURL.path) {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    private static func listTree(_ url: URL) -> [Planned] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if isDir.boolValue {
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            var out: [Planned] = []
            while let child = enumerator?.nextObject() as? URL {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true { continue }
                if let item = planned(child) { out.append(item) }
            }
            return out
        }
        return planned(url).map { [$0] } ?? []
    }

    private static func planned(_ url: URL) -> Planned? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey])
        if values?.isDirectory == true { return nil }
        let size = Int64(values?.fileSize ?? 0)
        let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        return Planned(source: url, name: url.lastPathComponent, size: size, bookmark: bookmark)
    }

    private static func streamCopy(from src: URL, to dest: URL) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
        }
    }

    struct ImportedFile: Transferable {
        let url: URL
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .item) { file in
                SentTransferredFile(file.url)
            } importing: { received in
                let dest = Pan115Inbox.uniqueURL(received.file.lastPathComponent)
                try Pan115Inbox.copyFile(from: received.file, to: dest)
                return ImportedFile(url: dest)
            }
        }
    }

    private static func uniqueName(_ raw: String) -> String {
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(raw).path) { return raw }
        let base = (raw as NSString).deletingPathExtension
        let ext = (raw as NSString).pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { return name }
            n += 1
        }
    }
}
