import Foundation
import UniformTypeIdentifiers

@MainActor
final class Pan115Uploader: NSObject, ObservableObject {
    static let shared = Pan115Uploader()

    @Published private(set) var jobs: [Job] = []

    struct Job: Identifiable {
        enum Status: String {
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
        var progress: Double {
            guard size > 0 else { return 0 }
            return min(1, Double(sent) / Double(size))
        }
    }

    private var tasks: [UUID: URLSessionUploadTask] = [:]
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var session: URLSession!
    private var running = false
    private var pausedIDs = Set<UUID>()
    private var cancelledIDs = Set<UUID>()

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func enqueue(fileURL: URL, name: String, size: Int64, cid: String) {
        let job = Job(id: UUID(), name: name, size: size, sent: 0, status: .waiting, message: "排队中", fileURL: fileURL, cid: cid)
        jobs.insert(job, at: 0)
        pump()
    }

    func pause(_ id: UUID) {
        pausedIDs.insert(id)
        tasks[id]?.suspend()
        update(id) { $0.status = .paused; $0.message = "已暂停" }
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
    }

    func cancel(_ id: UUID) {
        cancelledIDs.insert(id)
        pausedIDs.remove(id)
        tasks[id]?.cancel()
        tasks[id] = nil
        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(throwing: CancellationError())
        }
        update(id) { $0.status = .cancelled; $0.message = "已取消" }
        pump()
    }

    func pauseAll() { jobs.filter { $0.status == .waiting || $0.status == .uploading || $0.status == .hashing }.forEach { pause($0.id) } }
    func resumeAll() { jobs.filter { $0.status == .paused }.forEach { resume($0.id) } }
    func cancelAll() { jobs.filter { $0.status != .done && $0.status != .cancelled }.forEach { cancel($0.id) } }

    func removeFinished() {
        jobs.removeAll { $0.status == .done || $0.status == .failed || $0.status == .cancelled }
    }

    private func pump() {
        guard !running else { return }
        guard let next = jobs.first(where: { $0.status == .waiting && !pausedIDs.contains($0.id) && !cancelledIDs.contains($0.id) }) else { return }
        running = true
        Task { await run(next) }
    }

    private func run(_ job: Job) async {
        defer {
            running = false
            pump()
        }
        guard !cancelledIDs.contains(job.id), !pausedIDs.contains(job.id) else { return }
        update(job.id) { $0.status = .hashing; $0.message = "计算 SHA1" }
        do {
            let hashes = try Pan115API.fileSHA1(url: job.fileURL)
            guard !cancelledIDs.contains(job.id) else { return }
            while pausedIDs.contains(job.id) {
                try await Task.sleep(nanoseconds: 300_000_000)
                if cancelledIDs.contains(job.id) { return }
            }
            update(job.id) { $0.status = .uploading; $0.message = "初始化上传" }
            let ticket = try await Pan115API.initUpload(
                fileName: job.name, size: job.size, sha1: hashes.full, preSha1: hashes.head, dirID: job.cid
            )
            if ticket.rapid {
                update(job.id) { $0.status = .done; $0.sent = $0.size; $0.message = "秒传完成" }
                return
            }
            try await uploadForm(job: job, ticket: ticket)
            if cancelledIDs.contains(job.id) { return }
            if pausedIDs.contains(job.id) {
                update(job.id) { $0.status = .paused; $0.message = "已暂停" }
                return
            }
            update(job.id) { $0.status = .done; $0.sent = $0.size; $0.message = "上传完成" }
        } catch is CancellationError {
            update(job.id) { $0.status = .cancelled; $0.message = "已取消" }
        } catch {
            if cancelledIDs.contains(job.id) {
                update(job.id) { $0.status = .cancelled; $0.message = "已取消" }
            } else {
                update(job.id) { $0.status = .failed; $0.message = error.localizedDescription }
            }
        }
    }

    private func uploadForm(job: Job, ticket info: Pan115API.InitUpload) async throws {
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
        let footer = "\r\n--\(boundary)--\r\n".data(using: .utf8)!
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("115-\(job.id.uuidString).form")
        try assemble(header: header, file: job.fileURL, footer: footer, output: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

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

    private func assemble(header: Data, file: URL, footer: Data, output: URL) throws {
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

    private func update(_ id: UUID, _ body: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[i]
        body(&job)
        jobs[i] = job
    }
}

extension Pan115Uploader: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let raw = task.taskDescription, let id = UUID(uuidString: raw) else { return }
        Task { @MainActor in
            self.update(id) {
                $0.sent = min($0.size, max(0, totalBytesSent))
                if $0.status == .uploading { $0.message = "上传中" }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let raw = task.taskDescription, let id = UUID(uuidString: raw) else { return }
        Task { @MainActor in
            self.tasks[id] = nil
            guard let cont = self.continuations.removeValue(forKey: id) else { return }
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
        }
    }
}
