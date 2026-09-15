import Foundation
import Security
import SwiftUI

/// 115 登录 Cookie 与录像上传目标目录。Cookie 只写入本机 Keychain。
@MainActor
final class Pan115Session: ObservableObject {
    static let shared = Pan115Session()
    @Published private(set) var hasCookie = false
    @Published var targetCID: String {
        didSet { UserDefaults.standard.set(targetCID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: cidKey) }
    }

    private let service = "com.xy0305.WebCam.115"
    private let account = "cookie"
    private let cidKey = "camweb.115.targetCID"

    private init() {
        targetCID = UserDefaults.standard.string(forKey: cidKey) ?? "0"
        hasCookie = cookieHeader != nil
    }

    var cookieHeader: String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func save(_ raw: String) -> Bool {
        let pairs = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("=") }
        let names = Set(pairs.compactMap { $0.split(separator: "=", maxSplits: 1).first?.uppercased() })
        guard ["UID", "CID", "SEID"].allSatisfy(names.contains) else { return false }
        let value = pairs.joined(separator: "; ")
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8)
        ] as CFDictionary, nil)
        hasCookie = status == errSecSuccess
        return hasCookie
    }

    func clear() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        hasCookie = false
    }

    var validCID: String? {
        let value = targetCID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.allSatisfy(\.isNumber) ? value : nil
    }
}
