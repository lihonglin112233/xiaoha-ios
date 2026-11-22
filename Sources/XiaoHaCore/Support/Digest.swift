import Foundation

// 纯 Swift 实现散列与 AES：Linux 上没有 CryptoKit，为保证同一份代码在 iOS 与
// 本机测试环境行为一致，这里不依赖平台加密库。全部算法经 Java 基准向量校验。

public enum Digest {
    // MARK: - SHA-256

    static let sha256K: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let chunked = pad(message, bigEndianLength: true)
        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < chunked.count {
            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = UInt32(chunked[j]) << 24 | UInt32(chunked[j + 1]) << 16 | UInt32(chunked[j + 2]) << 8 | UInt32(chunked[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ sha256K[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            offset += 64
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for value in h {
            out.append(UInt8((value >> 24) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    // MARK: - SHA-1

    public static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        let chunked = pad(message, bigEndianLength: true)
        var offset = 0
        while offset < chunked.count {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = UInt32(chunked[j]) << 24 | UInt32(chunked[j + 1]) << 16 | UInt32(chunked[j + 2]) << 8 | UInt32(chunked[j + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = temp
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
            offset += 64
        }
        var out = [UInt8]()
        out.reserveCapacity(20)
        for value in h {
            out.append(UInt8((value >> 24) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    // MARK: - MD5

    static let md5S: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    static let md5K: [UInt32] = (0..<64).map { i in
        UInt32(truncatingIfNeeded: Int64((abs(sin(Double(i) + 1)) * 4294967296.0).rounded(.down)))
    }

    public static func md5(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476
        let chunked = pad(message, bigEndianLength: false)
        var offset = 0
        while offset < chunked.count {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = offset + i * 4
                m[i] = UInt32(chunked[j]) | UInt32(chunked[j + 1]) << 8 | UInt32(chunked[j + 2]) << 16 | UInt32(chunked[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d); g = i
                case 16..<32:
                    f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d; g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d); g = (7 * i) % 16
                }
                let temp = d
                d = c
                c = b
                let sum = a &+ f &+ md5K[i] &+ m[g]
                b = b &+ rotl(sum, md5S[i])
                a = temp
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
            offset += 64
        }
        var out = [UInt8]()
        out.reserveCapacity(16)
        for value in [a0, b0, c0, d0] {
            out.append(UInt8(value & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 24) & 0xFF))
        }
        return out
    }

    // MARK: - HMAC-SHA1

    public static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var block = key
        if block.count > 64 { block = sha1(block) }
        if block.count < 64 { block += [UInt8](repeating: 0, count: 64 - block.count) }
        var inner = [UInt8]()
        inner.reserveCapacity(64 + message.count)
        inner += block.map { $0 ^ 0x36 }
        inner += message
        let innerHash = sha1(inner)
        var outer = [UInt8]()
        outer.reserveCapacity(84)
        outer += block.map { $0 ^ 0x5C }
        outer += innerHash
        return sha1(outer)
    }

    // MARK: - helpers

    static func pad(_ message: [UInt8], bigEndianLength: Bool) -> [UInt8] {
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        if bigEndianLength {
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
            }
        } else {
            for shift in stride(from: 0, through: 56, by: 8) {
                data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
            }
        }
        return data
    }

    @inline(__always)
    static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    @inline(__always)
    static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}
