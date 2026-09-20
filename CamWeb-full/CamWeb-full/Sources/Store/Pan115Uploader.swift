import Foundation
import UIKit

@MainActor
final class Pan115Uploader: NSObject, ObservableObject {
    static let shared = Pan115Uploader()
    static let sessionID = "com.personal.camweb.115.upload"

    @Published private(set) var jobs: [Job] = []

    struct Job: Identifiable, Codable, Equatable {
        enum Status: String, Codable {
            case waiting, hashing, uploading, paused, done, failed, cancelled
        }
        let id: UUID
        var name: String
        var size: Int64
        var sent: Int64
        var status: Status
        var message: String
        var fileURL: URL
        var cid: String
        var folderName: String
        var ownsFile: Bool
        var bookmark: Data?
        var speedBps: Double
        var createdAt: Date
        var finishedAt: Date?
        var progress: Double {
            guard size > 0 else { return 0 }
            return min(1, Double(sent) / Double(size))
        }
    }

    private var tasks: [UUID: URLSessionUploadTask] = [:]
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var lastTick: [UUID: (sent: Int64, at: Date)] = [:]
    private var session: URLSession!
    private var running = false
    private var pausedIDs = Set<UUID>()
    private var cancelledIDs = Set<UUID>()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundCompletion: (() -> Void)?
    private let storeURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("115-jobs.json")
    }()

    var activeJobs: [Job] { jobs.filter { $0.status != .done && $0.status != .cancelled } }
    var historyJobs: [Job] { jobs.filter { $0.status == .done }.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) } }
    var failedJobs: [Job] { jobs.filter { $0.status == .failed } }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        jobs = Self.load(storeURL)
        Pan115Inbox.sweep(keeping: jobs.compactMap { job in
            (job.ownsFile && job.status != .done && job.status != .cancelled) ? job.fileURL : nil
        })
        pump()
    }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionID else { completion(); return }
        backgroundCompletion = completion
    }

    func enqueue(fileURL: URL, name: String, size: Int64, cid: String, folderName: String, ownsFile: Bool, bookmark: Data? = nil) {
        enqueueMany([
            Job(
                id: UUID(), name: name, size: max(size, 1), sent: 0, status: .waiting,
                message: "排队中", fileURL: fileURL, cid: cid, folderName: folderName,
                ownsFile: ownsFile, bookmark: bookmark, speedBps: 0, createdAt: Date(), finishedAt: nil
            )
        ])
    }

    func enqueueMany(_ items: [Job]) {
        guard !items.isEmpty else { return }
        jobs.insert(contentsOf: items, at: 0)
        persist()
        extendBackground()
        pump()
    }

    func pause(_ id: UUID) {
        pausedIDs.insert(id)
        tasks[id]?.suspend()
        update(id) { $0.status = .paused; $0.message = "已暂停"; $0.speedBps = 0 }
        persist()
    }

    func resume(_ id: UUID) {
        pausedIDs.remove(id)
        if let task = tasks[id] {
            update(id) { $0.status = .uploading; $0.message = "继续上传" }
            task.resume()
        } else {
            update(id) { $0.status = .waiting; $0.message = "排队中" }
            pump()
        }
        persist()
    }

    func cancel(_ id: UUID) {
        cancelledIDs.insert(id)
        pausedIDs.remove(id)
        tasks[id]?.cancel()
        tasks[id] = nil
        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(throwing: CancellationError())
        }
        if let job = jobs.first(where: { $0.id == id }) { cleanup(job) }
        update(id) { $0.status = .cancelled; $0.message = "已取消"; $0.speedBps = 0; $0.finishedAt = Date() }
        persist()
        pump()
    }

    func pauseAll() { activeJobs.forEach { pause($0.id) } }
    func resumeAll() { jobs.filter { $0.status == .paused }.forEach { resume($0.id) } }
    func cancelAll() { activeJobs.forEach { cancel($0.id) } }

    func removeHistory() {
        jobs.removeAll { $0.status == .done || $0.status == .cancelled }
        persist()
    }

    func keepAlive() { if !activeJobs.isEmpty { extendBackground() } }

    private func pump() {
        guard !running else { return }
        guard let next = jobs.first(where: { $0.status == .waiting && !pausedIDs.contains($0.id) && !cancelledIDs.contains($0.id) }) else {
            if activeJobs.isEmpty { endBackground() }
            return
        }
        running = true
        extendBackground()
        Task { await run(next) }
    }

    private func run(_ job: Job) async {
        defer {
            running = false
            persist()
            pump()
        }
        guard !cancelledIDs.contains(job.id), !pausedIDs.contains(job.id) else { return }
        update(job.id) { $0.status = .hashing; $0.message = "计算 SHA1" }
        persist()
        var scoped: URL?
        do {
            let source = try resolveSource(job)
            scoped = source.stop
            let url = source.url
            let hashes = try await Task.detached(priority: .utility) {
                try Pan115API.fileSHA1(url: url)
            }.value
            guard !cancelledIDs.contains(job.id) else { return }
            while pausedIDs.contains(job.id) {
                try await Task.sleep(nanoseconds: 300_000_000)
                if cancelledIDs.contains(job.id) { return }
            }
            update(job.id) { $0.status = .uploading; $0.message = "初始化上传" }
            persist()
            let ticket = try await Pan115API.initUpload(
                fileName: job.name, size: job.size, sha1: hashes.full, preSha1: hashes.head, dirID: job.cid
            )
            if ticket.rapid {
                finish(job.id, message: "秒传完成")
                return
            }
            try await uploadForm(job: job, file: url, ticket: ticket)
            if cancelledIDs.contains(job.id) { return }
            if pausedIDs.contains(job.id) {
                update(job.id) { $0.status = .paused; $0.message = "已暂停"; $0.speedBps = 0 }
                return
            }
            finish(job.id, message: "上传完成")
        } catch is CancellationError {
            update(job.id) { $0.status = .cancelled; $0.message = "已取消"; $0.finishedAt = Date() }
            if let current = jobs.first(where: { $0.id == job.id }) { cleanup(current) }
        } catch {
            if cancelledIDs.contains(job.id) {
                update(job.id) { $0.status = .cancelled; $0.message = "已取消"; $0.finishedAt = Date() }
                if let current = jobs.first(where: { $0.id == job.id }) { cleanup(current) }
            } else {
                update(job.id) { $0.status = .failed; $0.message = error.localizedDescription; $0.speedBps = 0 }
            }
        }
        if let stop = scoped { stop.stopAccessingSecurityScopedResource() }
    }

    private func resolveSource(_ job: Job) throws -> (url: URL, stop: URL?) {
        if let data = job.bookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let ok = url.startAccessingSecurityScopedResource()
            return (url, ok ? url : nil)
        }
        let access = job.fileURL.startAccessingSecurityScopedResource()
        if access || FileManager.default.isReadableFile(atPath: job.fileURL.path) {
            return (job.fileURL, access ? job.fileURL : nil)
        }
        throw Pan115API.APIError.message("找不到原文件，请重新选择")
    }

    private func finish(_ id: UUID, message: String) {
        if let job = jobs.first(where: { $0.id == id }) { cleanup(job) }
        update(id) {
            $0.status = .done
            $0.sent = $0.size
            $0.message = message
            $0.speedBps = 0
            $0.finishedAt = Date()
        }
        persist()
    }

    private func uploadForm(job: Job, file: URL, ticket info: Pan115API.InitUpload) async throws {
        let boundary = "----CamWeb115\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let host = info.host.hasPrefix("http") ? info.host : "https://\(info.host)"
        guard let url = URL(string: host) else { throw Pan115API.APIError.badResponse }

        var fields: [(String, String)] = []
        if !info.accessKeyId.isEmpty { fields.append(("OSSAccessKeyId", info.accessKeyId)) }
        if !info.formPolicy.isEmpty { fields.append(("policy", info.formPolicy)) }
        if !info.formSignature.isEmpty { fields.append(("signature", info.formSignature)) }
        fields.append(("key", info.object))
        if !info.callback.isEmpty { fields.append(("callback", info.callback)) }
        if !info.callbackVar.isEmpty { fields.append(("callback-var", info.callbackVar)) }
        if !info.securityToken.isEmpty { fields.append(("x-oss-security-token", info.securityToken)) }
        fields.append(("name", job.name))

        let header = multipartHeader(fields: fields, filename: job.name, boundary: boundary)
        let footer = Data("\r\n--\(boundary)--\r\n".utf8)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("115-\(job.id.uuidString).form")
        try await Task.detached(priority: .utility) {
            try Self.assemble(header: header, file: file, footer: footer, output: temp)
        }.value

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(Pan115API.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        if let cookie = Pan115Session.shared.cookieHeader { req.setValue(cookie, forHTTPHeaderField: "Cookie") }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuations[job.id] = cont
            let task = session.uploadTask(with: req, fromFile: temp)
            task.taskDescription = job.id.uuidString
            tasks[job.id] = task
            task.resume()
        }
        try? FileManager.default.removeItem(at: temp)
    }

    private func multipartHeader(fields: [(String, String)], filename: String, boundary: String) -> Data {
        var s = ""
        for (k, v) in fields {
            s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        s += "Content-Type: application/octet-stream\r\n\r\n"
        return Data(s.utf8)
    }

    nonisolated private static func assemble(header: Data, file: URL, footer: Data, output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        try out.write(contentsOf: header)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while true {
            let chunk = (try? input.read(upToCount: 1024 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: footer)
    }

    private func cleanup(_ job: Job) {
        guard job.ownsFile else { return }
        try? FileManager.default.removeItem(at: job.fileURL)
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("115Inbox", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil), files.isEmpty {
            try? FileManager.default.removeItem(at: inbox)
        }
    }

    private func update(_ id: UUID, _ body: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[i]
        body(&job)
        jobs[i] = job
    }

    private func persist() {
        let active = jobs.filter { $0.status != .done && $0.status != .cancelled }
        let history = jobs.filter { $0.status == .done || $0.status == .cancelled }.prefix(80)
        jobs = active + Array(history)
        if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private static func load(_ url: URL) -> [Job] {
        guard let data = try? Data(contentsOf: url),
              var items = try? JSONDecoder().decode([Job].self, from: data) else { return [] }
        for i in items.indices where items[i].status == .hashing || items[i].status == .uploading {
            items[i].status = .waiting
            items[i].message = "排队中"
            items[i].speedBps = 0
        }
        return items
    }

    private func extendBackground() {
        if bgTask != .invalid { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "115-upload") { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}

extension Pan115Uploader: URLSessionTaskDelegate, URLSessionDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let raw = task.taskDescription, let id = UUID(uuidString: raw) else { return }
        let now = Date()
        Task { @MainActor in
            var speed = 0.0
            if let prev = self.lastTick[id] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.25 {
                    speed = Double(totalBytesSent - prev.sent) / dt
                    self.lastTick[id] = (totalBytesSent, now)
                }
            } else {
                self.lastTick[id] = (totalBytesSent, now)
            }
            self.update(id) {
                $0.sent = min($0.size, max(0, totalBytesSent))
                if $0.status == .uploading {
                    $0.message = "上传中"
                    if speed > 0 { $0.speedBps = speed }
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let raw = task.taskDescription, let id = UUID(uuidString: raw) else { return }
        Task { @MainActor in
            self.tasks[id] = nil
            self.lastTick[id] = nil
            if let cont = self.continuations.removeValue(forKey: id) {
                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    cont.resume(throwing: Pan115API.APIError.httpStatus(http.statusCode))
                    return
                }
                cont.resume()
                return
            }
            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    self.update(id) { $0.status = .cancelled; $0.message = "已取消"; $0.finishedAt = Date() }
                } else {
                    self.update(id) { $0.status = .failed; $0.message = error.localizedDescription }
                }
            } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.update(id) { $0.status = .failed; $0.message = "HTTP \(http.statusCode)" }
            } else {
                self.finish(id, message: "上传完成")
            }
            self.persist()
            self.pump()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let done = self.backgroundCompletion
            self.backgroundCompletion = nil
            done?()
        }
    }
}
