import Foundation
import Security
import SwiftUI

final class Pan115Session: ObservableObject {
    static let shared = Pan115Session()
    @Published private(set) var hasCookie = false
    @Published var userID: String = ""
    @Published var userName: String = ""
    @Published var targetCID: String = UserDefaults.standard.string(forKey: "camweb.115.cid") ?? "0"

    private let service = "com.xy0305.WebCam.115"
    private let account = "cookie"
    private let lock = NSLock()
    private var cachedCookie: String?

    private init() {
        cachedCookie = loadCookie()
        hasCookie = cachedCookie != nil
        if hasCookie {
            Task { await refreshAccount() }
        }
    }

    var cookieHeader: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedCookie
    }

    func setTargetCID(_ cid: String) {
        let value = cid.trimmingCharacters(in: .whitespacesAndNewlines)
        targetCID = value.isEmpty ? "0" : value
        UserDefaults.standard.set(targetCID, forKey: "camweb.115.cid")
    }

    @discardableResult
    func save(_ raw: String) -> Bool {
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("=") }
        let names = Set(pairs.map { $0.split(separator: "=", maxSplits: 1).first.map { String($0).uppercased() } ?? "" })
        guard names.contains("UID"), names.contains("CID"), names.contains("SEID") else { return false }
        let value = pairs.joined(separator: "; ")
        persist(value)
        Task { await refreshAccount() }
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
        persist(pairs.joined(separator: "; "))
        Task { await refreshAccount() }
        return true
    }

    func clear() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
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
                self.userID = info.id
                self.userName = info.name
            }
        } catch {
            await MainActor.run {
                if self.userName.isEmpty { self.userName = "已登录" }
            }
        }
    }

    private func persist(_ value: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: value.data(using: .utf8)!
        ] as CFDictionary, nil)
        lock.lock(); cachedCookie = status == errSecSuccess ? value : nil; lock.unlock()
        DispatchQueue.main.async { self.hasCookie = status == errSecSuccess }
    }

    private func loadCookie() -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
