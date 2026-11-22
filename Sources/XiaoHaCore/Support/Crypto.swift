import Foundation

/// 纯 Swift AES-128/256 实现（只用于 G_A 信封的 CBC/PKCS5 加解密）。
enum AES {
    static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    static let invSbox: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { table[Int(sbox[i])] = UInt8(i) }
        return table
    }()

    static let rcon: [UInt8] = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]

    static func xtime(_ x: UInt8) -> UInt8 {
        (x << 1) ^ (((x >> 7) & 1) * 0x1b)
    }

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var x = a
        var y = b
        while y != 0 {
            if y & 1 != 0 { result ^= x }
            x = xtime(x)
            y >>= 1
        }
        return result
    }

    static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        let nk = key.count / 4
        let rounds = nk + 6
        let total = 4 * (rounds + 1)
        var w = [[UInt8]](repeating: [0, 0, 0, 0], count: total)
        for i in 0..<nk {
            w[i] = Array(key[i * 4..<(i * 4 + 4)])
        }
        for i in nk..<total {
            var temp = w[i - 1]
            if i % nk == 0 {
                temp = [temp[1], temp[2], temp[3], temp[0]].map { sbox[Int($0)] }
                temp[0] ^= rcon[i / nk]
            } else if nk > 6 && i % nk == 4 {
                temp = temp.map { sbox[Int($0)] }
            }
            w[i] = (0..<4).map { w[i - nk][$0] ^ temp[$0] }
        }
        return w
    }

    static func encryptBlock(_ block: [UInt8], roundKeys: [[UInt8]], rounds: Int) -> [UInt8] {
        var state = (0..<4).map { r in (0..<4).map { c in block[r + 4 * c] ^ roundKeys[c][r] } }
        for round in 1...rounds {
            for r in 0..<4 { for c in 0..<4 { state[r][c] = sbox[Int(state[r][c])] } }
            // ShiftRows: 第 r 行左移 r 位
            state = (0..<4).map { r in (0..<4).map { c in state[r][(c + r) % 4] } }
            if round != rounds {
                for c in 0..<4 {
                    let a0 = state[0][c], a1 = state[1][c], a2 = state[2][c], a3 = state[3][c]
                    state[0][c] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3
                    state[1][c] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3
                    state[2][c] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3)
                    state[3][c] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3)
                }
            }
            for c in 0..<4 {
                for r in 0..<4 {
                    state[r][c] ^= roundKeys[round * 4 + c][r]
                }
            }
        }
        return (0..<16).map { i in state[i % 4][i / 4] }
    }

    static func decryptBlock(_ block: [UInt8], roundKeys: [[UInt8]], rounds: Int) -> [UInt8] {
        var state = (0..<4).map { r in (0..<4).map { c in block[r + 4 * c] ^ roundKeys[rounds * 4 + c][r] } }
        for round in stride(from: rounds - 1, through: 0, by: -1) {
            state = (0..<4).map { r in (0..<4).map { c in state[r][(c - r + 8) % 4] } }
            for r in 0..<4 { for c in 0..<4 { state[r][c] = invSbox[Int(state[r][c])] } }
            for c in 0..<4 { for r in 0..<4 { state[r][c] ^= roundKeys[round * 4 + c][r] } }
            if round != 0 {
                for c in 0..<4 {
                    let a0 = state[0][c], a1 = state[1][c], a2 = state[2][c], a3 = state[3][c]
                    state[0][c] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9)
                    state[1][c] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13)
                    state[2][c] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11)
                    state[3][c] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14)
                }
            }
        }
        return (0..<16).map { i in state[i % 4][i / 4] }
    }

    static func cbcEncrypt(data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let roundKeys = expandKey(key)
        let rounds = key.count / 4 + 6
        // PKCS5/PKCS7 填充
        let padLength = 16 - (data.count % 16)
        var padded = data
        padded += [UInt8](repeating: UInt8(padLength), count: padLength)
        var previous = iv
        var out = [UInt8]()
        out.reserveCapacity(padded.count)
        var offset = 0
        while offset < padded.count {
            let block = Array(padded[offset..<(offset + 16)])
            let xored = (0..<16).map { block[$0] ^ previous[$0] }
            let encrypted = encryptBlock(xored, roundKeys: roundKeys, rounds: rounds)
            out += encrypted
            previous = encrypted
            offset += 16
        }
        return out
    }

    static func cbcDecrypt(data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty, data.count % 16 == 0 else { return nil }
        let roundKeys = expandKey(key)
        let rounds = key.count / 4 + 6
        var previous = iv
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var offset = 0
        while offset < data.count {
            let block = Array(data[offset..<(offset + 16)])
            var decrypted = decryptBlock(block, roundKeys: roundKeys, rounds: rounds)
            for i in 0..<16 { decrypted[i] ^= previous[i] }
            out += decrypted
            previous = block
            offset += 16
        }
        guard let padLength = out.last.map({ Int($0) }), padLength >= 1, padLength <= 16, out.count >= padLength else {
            return nil
        }
        guard out.suffix(padLength).allSatisfy({ Int($0) == padLength }) else { return nil }
        return Array(out.dropLast(padLength))
    }
}

/// 与原 APK 的 Base64Codec 行为一致（无 '=' 时也能解码，遇 '=' 停止）。
public enum Base64Codec {
    static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    static let lookup: [Int] = {
        var table = [Int](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { table[Int(c.asciiValue!)] = i }
        table[61] = -2
        return table
    }()

    public static func encode(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        var out = String()
        var i = 0
        while i + 2 < bytes.count {
            let value = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            out.append(alphabet[(value >> 18) & 63])
            out.append(alphabet[(value >> 12) & 63])
            out.append(alphabet[(value >> 6) & 63])
            out.append(alphabet[value & 63])
            i += 3
        }
        let remaining = bytes.count - i
        if remaining == 1 {
            let value = Int(bytes[i]) << 16
            out.append(alphabet[(value >> 18) & 63])
            out.append(alphabet[(value >> 12) & 63])
            out += "=="
        } else if remaining == 2 {
            let value = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8
            out.append(alphabet[(value >> 18) & 63])
            out.append(alphabet[(value >> 12) & 63])
            out.append(alphabet[(value >> 6) & 63])
            out += "="
        }
        return out
    }

    public static func decode(_ text: String) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count * 3 / 4 + 3)
        var buffer = 0
        var bits = 0
        for scalar in text.utf8 {
            if scalar == 0x3D { break } // '='
            if scalar == 0x0A || scalar == 0x0D || scalar == 0x20 || scalar == 0x09 { continue }
            let index = Int(scalar)
            let value = index < 256 ? lookup[index] : -1
            if value < 0 { return nil }
            buffer = (buffer << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
    }
}
