import Foundation

struct Pan115BackupTask: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    var sourceBookmark: Data
    var sourcePath: String
    var sourceName: String
    var destinations: [Destination]
    var fsMonitor: Bool
    var fullScanInterval: TimeInterval
    var forceScanOnLaunch: Bool
    var scanOnCreate: Bool
    var scheduleEnabled: Bool
    var scheduleHour: Int
    var scheduleMinute: Int
    var filters: [FilterRule]
    var existPolicy: ExistPolicy
    var sourceDeletedPolicy: SourceDeletedPolicy
    var afterBackup: AfterBackup
    var syncDeleteFromDest: Bool
    var lastScanAt: Date?
    var lastError: String?
    var lastMessage: String?
    var uploadedCount: Int
    var skippedCount: Int

    struct Destination: Identifiable, Codable, Equatable {
        var id: UUID
        var cid: String
        var name: String
        var enabled: Bool
    }

    struct FilterRule: Identifiable, Codable, Equatable {
        enum Kind: String, Codable, CaseIterable {
            case include
            case exclude
            var title: String { self == .include ? "包含（白名单）" : "排除（黑名单）" }
        }
        enum Match: String, Codable, CaseIterable {
            case suffix, contains, glob, regex
            var title: String {
                switch self {
                case .suffix: return "扩展名"
                case .contains: return "文件名包含"
                case .glob: return "通配符"
                case .regex: return "正则"
                }
            }
        }
        var id: UUID
        var kind: Kind
        var match: Match
        var pattern: String
    }

    enum ExistPolicy: String, Codable, CaseIterable {
        case skip, overwrite, rename
        var title: String {
            switch self {
            case .skip: return "Skip"
            case .overwrite: return "Overwrite"
            case .rename: return "Rename"
            }
        }
        var detail: String {
            switch self {
            case .skip: return "Skip existing files"
            case .overwrite: return "Overwrite existing files"
            case .rename: return "Rename new files"
            }
        }
    }

    enum SourceDeletedPolicy: String, Codable, CaseIterable {
        case keep, deleteRemote
        var title: String { self == .keep ? "Keep" : "Delete" }
        var detail: String {
            self == .keep ? "Keep removed files" : "Delete remote when source is removed"
        }
    }

    enum AfterBackup: String, Codable, CaseIterable {
        case keepSource, deleteSource
        var title: String { self == .keepSource ? "Keep Source" : "Delete Source" }
        var detail: String {
            self == .keepSource
                ? "Keep source files after backup"
                : "Delete source files after backup"
        }
    }

    static func blank() -> Pan115BackupTask {
        Pan115BackupTask(
            id: UUID(),
            name: "未命名备份",
            enabled: true,
            sourceBookmark: Data(),
            sourcePath: "",
            sourceName: "",
            destinations: [],
            fsMonitor: true,
            fullScanInterval: 0,
            forceScanOnLaunch: false,
            scanOnCreate: true,
            scheduleEnabled: false,
            scheduleHour: 3,
            scheduleMinute: 0,
            filters: [],
            existPolicy: .skip,
            sourceDeletedPolicy: .keep,
            afterBackup: .keepSource,
            syncDeleteFromDest: false,
            lastScanAt: nil,
            lastError: nil,
            lastMessage: nil,
            uploadedCount: 0,
            skippedCount: 0
        )
    }

    var enabledDestinations: [Destination] { destinations.filter(\.enabled) }

    var intervalLabel: String {
        if fullScanInterval <= 0 { return "0 秒\n= 从不" }
        let s = Int(fullScanInterval)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分钟" }
        if s < 86400 { return "\(s / 3600) 小时" }
        return "\(s / 86400) 天"
    }

    func allows(fileName: String) -> Bool {
        let name = fileName
        let includes = filters.filter { $0.kind == .include }
        let excludes = filters.filter { $0.kind == .exclude }
        if !includes.isEmpty, !includes.contains(where: { $0.matches(name) }) {
            return false
        }
        if excludes.contains(where: { $0.matches(name) }) {
            return false
        }
        return true
    }
}

extension Pan115BackupTask.FilterRule {
    func matches(_ fileName: String) -> Bool {
        let name = fileName
        let lower = name.lowercased()
        let pat = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pat.isEmpty else { return false }
        switch match {
        case .suffix:
            var ext = pat
            if ext.hasPrefix(".") { ext.removeFirst() }
            return lower.hasSuffix("." + ext.lowercased()) || lower.hasSuffix(ext.lowercased())
        case .contains:
            return lower.contains(pat.lowercased())
        case .glob:
            let pred = NSPredicate(format: "SELF LIKE[c] %@", pat)
            return pred.evaluate(with: name)
        case .regex:
            return name.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

struct Pan115BackupManifest: Codable {
    struct Item: Codable {
        var relativePath: String
        var size: Int64
        var mtime: TimeInterval
        var destIDs: [String]
    }
    var items: [String: Item] = [:]
}
