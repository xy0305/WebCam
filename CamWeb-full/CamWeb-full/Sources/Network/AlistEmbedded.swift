import Foundation
import Alistlib

/// 对照 gendago/alist-ios + alist-expo：gomobile 的 Alistlib 在 App 内起 HTTP。
@MainActor
final class AlistEmbedded: ObservableObject {
    static let shared = AlistEmbedded()
    static let baseURL = "http://127.0.0.1:5244"
    static let clientID = "camweb-ios"
    static let adminPassword = "admin"

    @Published private(set) var running = false
    @Published var lastError: String?

    private let event = AlistEventSink()
    private let log = AlistLogSink()
    private let change = AlistChangeSink()
    private var bootTask: Task<Void, Error>?

    private init() {}

    func prepare() async {
        if running {
            if Pan115Session.shared.token == nil {
                await loginAdmin()
            }
            return
        }
        lastError = nil
        if bootTask == nil {
            let event = event
            let log = log
            let change = change
            bootTask = Task.detached(priority: .userInitiated) {
                try AlistBoot.run(event: event, log: log, change: change)
            }
        }
        do {
            try await bootTask?.value
            running = true
            await loginAdmin()
        } catch {
            bootTask = nil
            running = false
            lastError = error.localizedDescription
        }
    }

    func loginAdmin() async {
        Pan115Session.shared.setBaseURL(Self.baseURL)
        let userRaw = AlistlibGetAdminUsername()
        let user = userRaw.isEmpty ? "admin" : userRaw
        AlistlibSetAdminPassword(Self.adminPassword)
        do {
            let token = try await Pan115API.login(username: user, password: Self.adminPassword)
            Pan115Session.shared.setToken(token, user: user)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

enum AlistBoot {
    static func run(event: AlistEventSink, log: AlistLogSink, change: AlistChangeSink) throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AList", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AlistlibSetConfigData(root.path)
        AlistlibSetConfigLogStd(true)
        var err: NSError?
        AlistlibInit(event, log, &err)
        if let err { throw err }
        AlistlibStart(change)
        for _ in 0..<80 {
            if AlistlibIsRunning("http") { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NSError(domain: "AlistEmbedded", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "本机 Alist 没有在 5244 起来"
        ])
    }
}

final class AlistEventSink: NSObject, AlistlibEventProtocol {
    func onProcessExit(_ code: Int) {}
    func onShutdown(_ t: String?) {}
    func onStartError(_ t: String?, err: String?) {
        Task { @MainActor in
            AlistEmbedded.shared.lastError = err ?? t ?? "Alist 启动失败"
        }
    }
}

final class AlistLogSink: NSObject, AlistlibLogCallbackProtocol {
    func onLog(_ level: Int16, time: Int64, message: String?) {}
}

final class AlistChangeSink: NSObject, AlistlibDataChangeCallbackProtocol {
    func onChange(_ model: String?) {}
}
