import CryptoKit
import Foundation

enum StripchatMouflon {
    private static let lock = NSLock()
    private static var cached: [String: String] = [:]
    private static var fetchedAt: Date?
    private static let pattern = try! NSRegularExpression(
        pattern: #"_([^_]+)_(\d+(?:_part\d+)?)\.mp4"#
    )

    static func keys() async -> [String: String] {
        lock.lock()
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 3600, !cached.isEmpty {
            let copy = cached
            lock.unlock()
            return copy
        }
        lock.unlock()
        guard let url = URL(string: "https://mouflon.chantrail.com"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["keys"] as? [String: String],
              !raw.isEmpty else {
            lock.lock()
            let copy = cached
            lock.unlock()
            return copy
        }
        lock.lock()
        cached = raw
        fetchedAt = Date()
        lock.unlock()
        return raw
    }

    static func decrypt(_ url: String, pdkey: String?) -> String {
        guard let pdkey, !pdkey.isEmpty, let decoded = decryptURL(url, pdkey: pdkey) else { return url }
        return decoded
    }

    static func pdkey(for pkey: String?) -> String? {
        guard let pkey, !pkey.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cached[pkey]
    }

    static func decrypt(_ url: String, pkey: String?) -> String {
        decrypt(url, pdkey: pdkey(for: pkey))
    }

    private static func decryptURL(_ encodedURL: String, pdkey: String) -> String? {
        let range = NSRange(encodedURL.startIndex..., in: encodedURL)
        guard let match = pattern.firstMatch(in: encodedURL, range: range),
              let encRange = Range(match.range(at: 1), in: encodedURL) else {
            return nil
        }
        let encrypted = String(encodedURL[encRange])
        var reversed = String(encrypted.reversed())
        while reversed.count % 4 != 0 { reversed.append("=") }
        guard let encryptedBytes = Data(base64Encoded: reversed) else { return nil }
        let keyBytes = Data(SHA256.hash(data: Data(pdkey.utf8)))
        guard !keyBytes.isEmpty else { return nil }
        let decrypted = encryptedBytes.enumerated().map { offset, byte in
            byte ^ keyBytes[offset % keyBytes.count]
        }
        guard let decoded = String(bytes: decrypted, encoding: .utf8), !decoded.isEmpty else { return nil }
        return encodedURL.replacingOccurrences(of: encrypted, with: decoded)
    }
}
