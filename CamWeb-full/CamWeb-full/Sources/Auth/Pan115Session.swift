import Foundation
import Security
import SwiftUI

/// 115 Cookie 用来在本机 Alist 挂存储；列表/播放走 127.0.0.1:5244。
final class Pan115Session: ObservableObject {
    static let shared = Pan115Session()
    static let defaultBase = AlistEmbedded.baseURL

    @Published private(set) var hasCookie = false
    @Published var userID: String = ""
    @Published var userName: String = ""
    @Published var baseURL: String = Pan115Session.defaultBase
    @Published var targetCID: String = UserDefaults.standard.string(forKey: "camweb.115.cid") ?? "0"
    @Published var uploadCID: String = UserDefaults.standard.string(forKey: "camweb.115.upload.cid") ?? "0"
    @Published var uploadFolderName: String = UserDefaults.standard.string(forKey: "camweb.115.upload.folder") ?? "根目录"

    private let cookieService = "com.xy0305.WebCam.115"
    private let cookieAccount = "cookie"
    private let lock = NSLock()
    private var cachedCookie: String?
    private var cachedToken: String?

    private init() {
        cachedCookie = loadCookie()
        hasCookie = cachedCookie != nil
        if targetCID.hasPrefix("/") { targetCID = "0" }
        if uploadCID.hasPrefix("/") { uploadCID = "0" }
        if let raw = cachedCookie {
            applyUser(from: raw)
        }
    }

    var token: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedToken
    }

    var cookieHeader: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedCookie
    }

    var rootPath: String { "/115" }

    func setBaseURL(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { value = Self.defaultBase }
        baseURL = value
    }

    func setToken(_ token: String, user: String) {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); cachedToken = value.isEmpty ? nil : value; lock.unlock()
        DispatchQueue.main.async {
            if self.userName.isEmpty { self.userName = user }
        }
    }

    func setTargetCID(_ cid: String) {
        let value = cid.trimmingCharacters(in: .whitespacesAndNewlines)
        targetCID = value.isEmpty || value.hasPrefix("/") ? "0" : value
        UserDefaults.standard.set(targetCID, forKey: "camweb.115.cid")
    }

    func setUploadFolder(cid: String, name: String) {
        let value = cid.trimmingCharacters(in: .whitespacesAndNewlines)
        uploadCID = value.isEmpty || value.hasPrefix("/") ? "0" : value
        uploadFolderName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "根目录" : name
        UserDefaults.standard.set(uploadCID, forKey: "camweb.115.upload.cid")
        UserDefaults.standard.set(uploadFolderName, forKey: "camweb.115.upload.folder")
    }

    @discardableResult
    func save(_ raw: String) -> Bool {
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("=") }
        let names = Set(pairs.map { $0.split(separator: "=", maxSplits: 1).first.map { String($0).uppercased() } ?? "" })
        guard names.contains("UID"), names.contains("CID"), names.contains("SEID") else { return false }
        persistCookie(pairs.joined(separator: "; "))
        Task { await mount115() }
        return true
    }

    func saveFromWebCookies(_ cookies: [HTTPCookie]) -> Bool {
        let wanted = ["UID", "CID", "SEID", "KID"]
        var pairs: [String] = []
        for name in wanted {
            if let c = cookies.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.value.isEmpty }) {
                pairs.append("\(c.name)=\(c.value)")
            }
        }
        guard pairs.contains(where: { $0.uppercased().hasPrefix("UID=") }),
              pairs.contains(where: { $0.uppercased().hasPrefix("CID=") }),
              pairs.contains(where: { $0.uppercased().hasPrefix("SEID=") }) else { return false }
        persistCookie(pairs.joined(separator: "; "))
        Task { await mount115() }
        return true
    }

    func clear() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: cookieService, kSecAttrAccount: cookieAccount] as CFDictionary)
        lock.lock(); cachedCookie = nil; lock.unlock()
        DispatchQueue.main.async {
            self.hasCookie = false
            self.userID = ""
            self.userName = ""
        }
    }

    func refreshAccount() async {
        do {
            let info = try await Pan115API.userInfo()
            await MainActor.run {
                if self.userName.isEmpty { self.userName = info.name }
                if self.userID.isEmpty { self.userID = info.id }
            }
        } catch {}
    }

    func mount115() async {
        guard let cookie = cookieHeader, !cookie.isEmpty else { return }
        await AlistEmbedded.shared.prepare()
        do {
            try await Pan115API.ensure115Storage(cookie: cookie)
            await refreshAccount()
        } catch {
            await MainActor.run { AlistEmbedded.shared.lastError = error.localizedDescription }
        }
    }

    private func persistCookie(_ value: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: cookieService, kSecAttrAccount: cookieAccount] as CFDictionary)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: cookieService,
            kSecAttrAccount: cookieAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: value.data(using: .utf8)!
        ] as CFDictionary, nil)
        lock.lock(); cachedCookie = status == errSecSuccess ? value : nil; lock.unlock()
        applyUser(from: value)
        DispatchQueue.main.async { self.hasCookie = status == errSecSuccess }
    }

    private func applyUser(from cookie: String) {
        for part in cookie.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].uppercased() == "UID" else { continue }
            let uid = kv[1]
            DispatchQueue.main.async {
                self.userID = uid
                if self.userName.isEmpty { self.userName = uid }
            }
            return
        }
    }

    private func loadCookie() -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: cookieService,
            kSecAttrAccount: cookieAccount,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
