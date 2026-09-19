import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 直接 present 系统文件选择器。包进 SwiftUI sheet 时点「打开」经常没回调。
enum Pan115FilePicker {
    static func present(onPicked: @escaping ([URL]) -> Void) {
        present(types: [.item, .content, .data, .folder, .directory, .movie, .video, .image, .audio], asCopy: true, multiple: true) { onPicked($0) }
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
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("115Inbox", isDirectory: true)
    }

    static func ingest(_ urls: [URL]) -> [(url: URL, name: String, size: Int64)] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var out: [(URL, String, Int64)] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            out.append(contentsOf: copyTree(url, prefix: ""))
        }
        return out
    }

    private static func copyTree(_ url: URL, prefix: String) -> [(URL, String, Int64)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if isDir.boolValue {
            let children = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let folder = prefix.isEmpty ? url.lastPathComponent : "\(prefix)/\(url.lastPathComponent)"
            return children.flatMap { copyTree($0, prefix: folder) }
        }
        let destName = uniqueName(url.lastPathComponent)
        let dest = directory.appendingPathComponent(destName)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: url, to: dest)
        } catch {
            guard let data = try? Data(contentsOf: url) else { return [] }
            try? data.write(to: dest)
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        guard fm.fileExists(atPath: dest.path) else { return [] }
        return [(dest, url.lastPathComponent, size)]
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
