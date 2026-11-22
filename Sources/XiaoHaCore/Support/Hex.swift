import Foundation

/// 十六进制编码。与原 APK 中 GwmCrypto.bytesToHex（小写）和 toHexUpper（大写）保持一致。
public enum Hex {
    static let lowerTable: [Character] = Array("0123456789abcdef")
    static let upperTable: [Character] = Array("0123456789ABCDEF")

    public static func encodeLower(_ bytes: [UInt8]) -> String {
        var out = String()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(lowerTable[Int(b >> 4)])
            out.append(lowerTable[Int(b & 0x0F)])
        }
        return out
    }

    public static func encodeUpper(_ bytes: [UInt8]) -> String {
        var out = String()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(upperTable[Int(b >> 4)])
            out.append(upperTable[Int(b & 0x0F)])
        }
        return out
    }

    public static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }
}
