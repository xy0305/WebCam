import Foundation
import Security

/// 对照 115driver `pkg/crypto/m115`：OpenList 下载直链用这套加解密。
enum Pan115M115 {
    static func generateKey() -> Data {
        var key = Data(count: 16)
        key.withUnsafeMutableBytes { buf in
            guard let p = buf.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, p)
        }
        return key
    }

    static func encode(_ input: Data, key: Data) -> String {
        var payload = input
        xorTransform(&payload, key: xorDeriveKey(seed: key, size: 4))
        reverseBytes(&payload)
        xorTransform(&payload, key: xorClientKey)
        var buf = Data(key.prefix(16))
        buf.append(payload)
        return rsaEncrypt(buf).base64EncodedString()
    }

    static func decode(_ input: String, key: Data) throws -> Data {
        guard let raw = Data(base64Encoded: input) else {
            throw Pan115API.APIError.message("m115 解码失败")
        }
        let data = rsaDecrypt(raw)
        guard data.count > 16 else { throw Pan115API.APIError.message("m115 数据过短") }
        var output = Data(data.suffix(from: 16))
        xorTransform(&output, key: xorDeriveKey(seed: Data(data.prefix(16)), size: 12))
        reverseBytes(&output)
        xorTransform(&output, key: xorDeriveKey(seed: key, size: 4))
        return output
    }

    private static let xorKeySeed: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
    ]

    private static let xorClientKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18,
        0x4c, 0x01, 0x3f, 0x46
    ]

    private static func xorDeriveKey(seed: Data, size: Int) -> [UInt8] {
        let s = [UInt8](seed)
        var key = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            key[i] = (s[i] &+ xorKeySeed[size * i]) & 0xff
            key[i] ^= xorKeySeed[size * (size - i - 1)]
        }
        return key
    }

    private static func reverseBytes(_ data: inout Data) {
        var bytes = [UInt8](data)
        bytes.reverse()
        data = Data(bytes)
    }

    private static func xorTransform(_ data: inout Data, key: [UInt8]) {
        guard !key.isEmpty, !data.isEmpty else { return }
        data.withUnsafeMutableBytes { buf in
            guard let p = buf.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = buf.count
            let mod = n % 4
            if mod > 0 {
                for i in 0..<mod { p[i] ^= key[i % key.count] }
            }
            for i in mod..<n { p[i] ^= key[(i - mod) % key.count] }
        }
    }

    private static let rsaN = BigUInt(hex:
        "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
        "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
        "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
        "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
    )
    private static let rsaE = BigUInt(UInt64(0x10001))
    private static let keyLength = 128

    private static func rsaEncrypt(_ input: Data) -> Data {
        var remain = input
        var out = Data()
        while !remain.isEmpty {
            let n = min(keyLength - 11, remain.count)
            out.append(rsaEncryptSlice(remain.prefix(n)))
            remain = remain.dropFirst(n)
        }
        return out
    }

    private static func rsaEncryptSlice(_ input: Data) -> Data {
        let padSize = keyLength - input.count - 3
        var pad = Data(count: padSize)
        pad.withUnsafeMutableBytes { buf in
            guard let p = buf.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, padSize, p)
        }
        var buf = Data(count: keyLength)
        buf[0] = 0
        buf[1] = 2
        for i in 0..<padSize {
            buf[2 + i] = (pad[i] % 0xff) + 0x01
        }
        buf[padSize + 2] = 0
        buf.replaceSubrange((padSize + 3)..., with: input)
        let ret = BigUInt(buf).modPow(rsaE, modulus: rsaN).bytes(paddedTo: keyLength)
        return ret
    }

    private static func rsaDecrypt(_ input: Data) -> Data {
        var remain = input
        var out = Data()
        while !remain.isEmpty {
            let n = min(keyLength, remain.count)
            out.append(rsaDecryptSlice(remain.prefix(n)))
            remain = remain.dropFirst(n)
        }
        return out
    }

    private static func rsaDecryptSlice(_ input: Data) -> Data {
        let ret = BigUInt(Data(input)).modPow(rsaE, modulus: rsaN).bytes()
        if let idx = ret.firstIndex(of: 0), idx > 0 {
            return Data(ret.dropFirst(idx + 1))
        }
        return ret
    }
}

/// 1024-bit 模幂用的大整数（小端 32-bit limb）。
private struct BigUInt {
    var limbs: [UInt32]

    init(_ value: UInt64) {
        if value == 0 {
            limbs = [0]
        } else {
            limbs = [UInt32(value & 0xffffffff), UInt32(value >> 32)].filter { $0 != 0 || value > 0xffffffff }
            if limbs.isEmpty { limbs = [0] }
        }
        trim()
    }

    init(hex: String) {
        var bytes = [UInt8]()
        var s = hex
        if s.count % 2 == 1 { s = "0" + s }
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            bytes.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        self.init(Data(bytes))
    }

    init(_ data: Data) {
        if data.isEmpty {
            limbs = [0]
            return
        }
        var out: [UInt32] = []
        var i = data.count
        while i > 0 {
            let start = max(0, i - 4)
            var v: UInt32 = 0
            for b in data[start..<i] {
                v = (v << 8) | UInt32(b)
            }
            out.append(v)
            i = start
        }
        limbs = out
        trim()
    }

    func bytes(paddedTo size: Int? = nil) -> Data {
        if limbs.count == 1 && limbs[0] == 0 {
            return size.map { Data(count: $0) } ?? Data([0])
        }
        var out = Data()
        for limb in limbs.reversed() {
            out.append(UInt8((limb >> 24) & 0xff))
            out.append(UInt8((limb >> 16) & 0xff))
            out.append(UInt8((limb >> 8) & 0xff))
            out.append(UInt8(limb & 0xff))
        }
        while out.first == 0, out.count > 1 { out.removeFirst() }
        if let size, out.count < size {
            out.insert(contentsOf: repeatElement(UInt8(0), count: size - out.count), at: 0)
        }
        return out
    }

    mutating func trim() {
        while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() }
        if limbs.isEmpty { limbs = [0] }
    }

    func modPow(_ exp: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1)
        var base = self.modulo(modulus)
        var e = exp
        while !e.isZero {
            if e.limbs[0] & 1 == 1 {
                result = result.multiply(base).modulo(modulus)
            }
            e = e.shiftedRight()
            if !e.isZero {
                base = base.multiply(base).modulo(modulus)
            }
        }
        return result
    }

    var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }

    func shiftedRight() -> BigUInt {
        var carry: UInt32 = 0
        var out = limbs
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            let cur = out[i]
            out[i] = (cur >> 1) | (carry << 31)
            carry = cur & 1
        }
        var r = BigUInt(limbs: out)
        r.trim()
        return r
    }

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        trim()
    }

    func multiply(_ other: BigUInt) -> BigUInt {
        if isZero || other.isZero { return BigUInt(0) }
        var out = [UInt32](repeating: 0, count: limbs.count + other.limbs.count + 1)
        for i in 0..<limbs.count {
            var carry: UInt64 = 0
            for j in 0..<other.limbs.count {
                let t = UInt64(out[i + j]) + UInt64(limbs[i]) * UInt64(other.limbs[j]) + carry
                out[i + j] = UInt32(t & 0xffffffff)
                carry = t >> 32
            }
            var k = i + other.limbs.count
            while carry > 0 {
                let t = UInt64(out[k]) + carry
                out[k] = UInt32(t & 0xffffffff)
                carry = t >> 32
                k += 1
            }
        }
        var r = BigUInt(limbs: out)
        r.trim()
        return r
    }

    func modulo(_ m: BigUInt) -> BigUInt {
        if m.isZero { return self }
        if compare(m) < 0 { return self }
        var remainder = self
        let shift = bitWidth - m.bitWidth
        if shift < 0 { return self }
        for s in stride(from: shift, through: 0, by: -1) {
            let shifted = m.shiftLeft(s)
            if remainder.compare(shifted) >= 0 {
                remainder = remainder.subtract(shifted)
            }
        }
        remainder.trim()
        return remainder
    }

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    func shiftLeft(_ bits: Int) -> BigUInt {
        if bits == 0 || isZero { return self }
        let limbShift = bits / 32
        let b = bits % 32
        var out = [UInt32](repeating: 0, count: limbShift)
        var carry: UInt32 = 0
        for limb in limbs {
            out.append((limb << b) | carry)
            carry = b == 0 ? 0 : limb >> (32 - b)
        }
        if carry != 0 { out.append(carry) }
        var r = BigUInt(limbs: out)
        r.trim()
        return r
    }

    func compare(_ other: BigUInt) -> Int {
        if limbs.count != other.limbs.count {
            return limbs.count > other.limbs.count ? 1 : -1
        }
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            if limbs[i] != other.limbs[i] {
                return limbs[i] > other.limbs[i] ? 1 : -1
            }
        }
        return 0
    }

    func subtract(_ other: BigUInt) -> BigUInt {
        var out = limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            let sub = Int64(other.limbs.count > i ? other.limbs[i] : 0)
            var v = Int64(out[i]) - sub - borrow
            if v < 0 {
                v += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            out[i] = UInt32(v)
        }
        var r = BigUInt(limbs: out)
        r.trim()
        return r
    }
}
