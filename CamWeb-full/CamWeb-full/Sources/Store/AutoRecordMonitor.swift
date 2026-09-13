import Foundation

@MainActor
final class AutoRecordMonitor: ObservableObject {
    static let shared = AutoRecordMonitor()

    struct Entry: Codable, Identifiable, Hashable {
        var username: String
        var autoRecord: Bool
        var id: String { username }
    }

    enum State: Equatable {
        case idle, checking, online, offline, recording, failed(String)

        var title: String {
            switch self {
            case .idle: return "等待检测"
            case .checking: return "检测中"
            case .online: return "在线"
            case .offline: return "离线"
            case .recording: return "正在录制"
            case .failed: return "检测失败"
            }
        }
    }

    private enum Probe: Sendable {
        case online(String, ResolvedStream)
        case offline(String, String)
    }

    private let key = "camweb.autoRecord.entries.v1"
    @Published private(set) var entries: [Entry]
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var isChecking = false

    private var monitorTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.checkAll()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func add(_ raw: String) -> Bool {
        let name = normalize(raw)
        guard name.count >= 2, !entries.contains(where: { $0.username == name }) else { return false }
        entries.insert(Entry(username: name, autoRecord: true), at: 0)
        states[name] = .idle
        persist()
        Task { await check(name, autoStart: true) }
        return true
    }

    func remove(_ username: String) {
        let name = normalize(username)
        RecordingManager.shared.stop(name)
        entries.removeAll { $0.username == name }
        states[name] = nil
        persist()
    }

    func setAuto(_ enabled: Bool, for username: String) {
        guard let index = entries.firstIndex(where: { $0.username == username }) else { return }
        entries[index].autoRecord = enabled
        persist()
        if enabled {
            Task { await check(username, autoStart: true) }
        }
    }

    func manualStart(_ username: String) {
        setAuto(true, for: username)
        Task { await check(username, autoStart: true) }
    }

    func manualStop(_ username: String) {
        setAuto(false, for: username)
        RecordingManager.shared.stop(username)
        states[username] = .online
    }

    func state(for username: String) -> State {
        if RecordingManager.shared.isRecording(username) { return .recording }
        if states[username] == .recording { return .online }
        return states[username] ?? .idle
    }

    func checkAll() async {
        guard !isChecking, !entries.isEmpty else { return }
        isChecking = true
        // 正在录制说明已经确认在线；不再重复解析直播源，避免浪费请求和时间。
        let snapshot = entries.filter { !RecordingManager.shared.isRecording($0.username) }
        snapshot.forEach { states[$0.username] = .checking }

        await withTaskGroup(of: Probe.self) { group in
            for entry in snapshot {
                group.addTask {
                    do {
                        return .online(entry.username, try await StreamSource.resolve(username: entry.username))
                    } catch {
                        return .offline(entry.username, error.localizedDescription)
                    }
                }
            }
            for await result in group {
                switch result {
                case .online(let name, let stream):
                    guard let current = entries.first(where: { $0.username == name }) else { continue }
                    states[name] = .online
                    if current.autoRecord, !RecordingManager.shared.isRecording(name) {
                        RecordingManager.shared.start(
                            username: name,
                            videoPlaylist: stream.videoPlaylist,
                            audioPlaylist: stream.audioPlaylist,
                            masterURL: stream.masterURL
                        )
                        states[name] = .recording
                    }
                case .offline(let name, let reason):
                    states[name] = reason.localizedCaseInsensitiveContains("公开") ? .offline : .failed(reason)
                }
            }
        }
        isChecking = false
    }

    private func check(_ username: String, autoStart: Bool) async {
        // 手动重复点击开始时也不重新解析，已有录制任务直接复用。
        if RecordingManager.shared.isRecording(username) {
            states[username] = .recording
            return
        }
        states[username] = .checking
        do {
            let stream = try await StreamSource.resolve(username: username)
            states[username] = .online
            if autoStart, !RecordingManager.shared.isRecording(username) {
                RecordingManager.shared.start(
                    username: username,
                    videoPlaylist: stream.videoPlaylist,
                    audioPlaylist: stream.audioPlaylist,
                    masterURL: stream.masterURL
                )
                states[username] = .recording
            }
        } catch {
            states[username] = .offline
        }
    }

    private func normalize(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
