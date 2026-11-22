import Foundation

public enum GwmCryptoError: Error, LocalizedError {
    case invalidEnvelope(String)
    case unknownKeyId(Int)
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidEnvelope(reason): return reason
        case let .unknownKeyId(id): return "未知 keyId: \(id)"
        case .decryptionFailed: return "G_A 解密失败"
        }
    }
}

/// 车云接口的签名与信封加密，逐项对齐原 APK 的 GwmCrypto。
public enum GwmCrypto {
    public static let autoAiCkey = "ea49a50f914b8d38af1c84809d302683"
    static let autoAiPrivateKey = "dad377585f566b548c961a418dcec41a"
    public static let beanTechAppKey = "7863128529"
    static let beanTechSecret = "21382b32fea1d5fa03813d806d2dd64f"
    public static let defaultNoteId = "145765423214576567716671"
    public static let gAppAppId = "GWM-APP-ANDROID-1100018"
    public static let officialUserAgent = "okhttp/4.2.2"
    static let secret32 = "E3*138%pb=GcflmhmsaA4WU^J-f&0Ofe"
    static let secret36 = "t8X_MybKFjp-Kg^mt99ALe-ArGzJE5mpCOra"
    public static let sourceAppCode = "2150"
    public static let sourceAppVersion = "2.2.0"

    static let envelopePasswords: [Int: String] = [
        1: "Qin.1^0123456789abcdef0123456789abcdef0123456789abcdef012345cdef",
        2: "Gwn*9$0123456789abcdef0123456789abcdef0189abcdef0123456789abcdef",
    ]

    static let opensslMagic: [UInt8] = Array("Salted__".utf8)

    // MARK: - 摘要

    public static func md5Hex(_ text: String) -> String {
        Hex.encodeLower(Digest.md5(Array(text.utf8)))
    }

    public static func sha256Hex(_ text: String) -> String {
        Hex.encodeLower(Digest.sha256(Array(text.utf8)))
    }

    // MARK: - 时间

    /// 中国时区的 yyyyMMddHHmmss + 毫秒三位。
    public static func chinaTimestamp(date: Date = Date()) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = JavaMath.pad(Int64(parts.year ?? 0), width: 4)
            + JavaMath.pad(Int64(parts.month ?? 0), width: 2)
            + JavaMath.pad(Int64(parts.day ?? 0), width: 2)
            + JavaMath.pad(Int64(parts.hour ?? 0), width: 2)
            + JavaMath.pad(Int64(parts.minute ?? 0), width: 2)
            + JavaMath.pad(Int64(parts.second ?? 0), width: 2)
        return stamp + JavaMath.pad(millis % 1000, width: 3)
    }

    // MARK: - 随机

    public static func randomDeviceId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        return Hex.encodeUpper(bytes)
    }

    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let hex = Hex.encodeUpper(bytes)
        return String(sha256Hex(hex).prefix(16))
    }

    public static func randomSequence() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        return Hex.encodeLower(bytes) + String(Int.random(in: 1000...9999))
    }

    // MARK: - 签名

    public static func autoAiSign(_ time: String) -> String {
        let message = "SIGN_BODY=[]&SIGN_TIME=" + time
        let key = "C_KEY=\(autoAiCkey)&API_KEY=\(autoAiPrivateKey)"
        let mac = Digest.hmacSHA1(key: Array(key.utf8), message: Array(message.utf8))
        return Base64Codec.encode(mac)
    }

    public static func beanTechSign(_ method: String, _ path: String, _ nonce: String, _ timestamp: String, _ extra: String) -> String {
        var pathBuilder = "/"
        var first = true
        for raw in path.split(separator: "/", omittingEmptySubsequences: false) {
            let segment = String(raw)
            if segment.isEmpty { continue }
            if !first { pathBuilder += "/" }
            pathBuilder += JavaURL.decode(segment)
            first = false
        }
        let raw = method.uppercased()
            + pathBuilder
            + "bt-auth-appkey:\(beanTechAppKey)bt-auth-nonce:\(nonce)bt-auth-timestamp:\(timestamp)"
            + extra
            + beanTechSecret
        var encoded = JavaURL.javaUrlEncode(raw)
        for token in ["+", "%20", "%0A", "%09", "%0D"] {
            encoded = encoded.replacingOccurrences(of: token, with: "")
        }
        return sha256Hex(encoded)
    }

    static let signHeaderKeys = ["AppId", "Authorization", "DeviceId", "NoteId", "SourceApp", "SourceAppVer", "SourceType", "Timestamp"]

    public static func defaultSign(_ method: String, _ url: String, _ body: String?, _ headers: [String: String]) -> String {
        var builder = method.uppercased() + url
        for key in signHeaderKeys {
            builder += key.lowercased() + ":" + (headers[key] ?? "")
        }
        if method.uppercased() != "GET" {
            builder += "json=" + (body ?? "")
        }
        builder += deriveSecret(headers["Timestamp"], headers["DeviceId"], headers["Authorization"])
        return sha256Hex(builder)
    }

    /// 对应 Java 的 deriveSecret（注意 Java 侧对 null 与截取范围的精确行为）。
    public static func deriveSecret(_ timestamp: String?, _ deviceId: String?, _ authorization: String?) -> String {
        let parsed = Int64((timestamp ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let modulo = parsed % 100000
        var index = Int(modulo % 32)
        if index < 0 { index += 32 }
        var secret = secret36
        if (parsed & 1) == 1 {
            var transposed = ""
            transposed.reserveCapacity(36)
            let chars = Array(secret36)
            for column in 0..<6 {
                for row in 0..<6 {
                    transposed.append(chars[row * 6 + column])
                }
            }
            secret = transposed
        }
        let doubled = Array(secret + secret)
        let slice = String(doubled[index..<min(index + 6, doubled.count)])
        var deviceSlice = ""
        let deviceStart = Int(parsed % 8 < 0 ? parsed % 8 + 8 : parsed % 8)
        if let deviceId, deviceId.count >= deviceStart + 6 {
            let chars = Array(deviceId)
            deviceSlice = String(chars[deviceStart..<(deviceStart + 6)])
        }
        let auth = (authorization ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let authSlice = auth.count > 9 ? String(Array(auth)[3..<9]) : ""
        return secret32 + slice + deviceSlice + authSlice
    }

    // MARK: - 信封

    static func deriveOpenSSLKeyIv(_ password: String, salt: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        let passwordBytes = Array(password.utf8)
        var material = [UInt8]()
        var previous = [UInt8]()
        while material.count < 48 {
            previous = Digest.md5(previous + passwordBytes + salt)
            material += previous
        }
        return (Array(material[0..<32]), Array(material[32..<48]))
    }

    public static func encryptEnvelope(_ plaintext: String, keyId: Int, salt: [UInt8]) throws -> String {
        guard let password = envelopePasswords[keyId] else { throw GwmCryptoError.unknownKeyId(keyId) }
        let derived = deriveOpenSSLKeyIv(password, salt: salt)
        let cipher = AES.cbcEncrypt(data: Array(plaintext.utf8), key: derived.key, iv: derived.iv)
        let payload = opensslMagic + salt + cipher
        return "G_A(" + Base64Codec.encode(payload) + "," + String(keyId) + ")"
    }

    public static func encryptEnvelope(_ plaintext: String, keyId: Int) throws -> String {
        var salt = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { salt[i] = UInt8.random(in: 0...255) }
        return try encryptEnvelope(plaintext, keyId: keyId, salt: salt)
    }

    public static func decryptEnvelope(_ text: String?) throws -> String? {
        guard let text else { return nil }
        guard text.hasPrefix("G_A("), text.hasSuffix(")") else { return text }
        guard let commaIndex = text.lastIndex(of: ","),
              text.distance(from: text.startIndex, to: commaIndex) > 4 else {
            throw GwmCryptoError.invalidEnvelope("G_A 信封格式错误")
        }
        let keyIdText = text[text.index(after: commaIndex)..<text.index(before: text.endIndex)]
        guard let keyId = Int(keyIdText.trimmingCharacters(in: .whitespaces)) else {
            throw GwmCryptoError.invalidEnvelope("G_A keyId 非法")
        }
        guard let password = envelopePasswords[keyId] else { throw GwmCryptoError.unknownKeyId(keyId) }
        let start = text.index(text.startIndex, offsetBy: 4)
        let base64Body = String(text[start..<commaIndex])
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard let payload = Base64Codec.decode(base64Body) else {
            throw GwmCryptoError.invalidEnvelope("G_A 载荷格式错误")
        }
        guard payload.count >= 32, payload.count % 16 == 0 else {
            throw GwmCryptoError.invalidEnvelope("G_A 载荷格式错误")
        }
        guard Array(payload[0..<8]) == opensslMagic else {
            throw GwmCryptoError.invalidEnvelope("G_A 载荷格式错误")
        }
        let salt = Array(payload[8..<16])
        let derived = deriveOpenSSLKeyIv(password, salt: salt)
        guard let plain = AES.cbcDecrypt(data: Array(payload[16...]), key: derived.key, iv: derived.iv) else {
            throw GwmCryptoError.decryptionFailed
        }
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: - .NET 风格 JSON 编码（与原实现逐字符一致）

    public static func encodeDotnetJSON(_ value: JSONValue) -> String {
        var out = ""
        writeDotnetJSON(value, depth: 0, into: &out)
        return out
    }

    static func writeDotnetJSON(_ value: JSONValue, depth: Int, into out: inout String) {
        guard depth <= 32 else { return }
        switch value {
        case .null:
            out += "null"
        case let .bool(b):
            out += b ? "true" : "false"
        case let .number(n):
            if n != JavaMath.rint(n) || n.isInfinite {
                out += JavaMath.doubleToString(n)
            } else {
                out += String(JavaMath.truncate(n))
            }
        case let .string(s):
            writeDotnetString(s, into: &out)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                writeDotnetJSON(item, depth: depth + 1, into: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                writeDotnetString(pair.0, into: &out)
                out += ":"
                writeDotnetJSON(pair.1, depth: depth + 1, into: &out)
            }
            out += "}"
        }
    }

    static let htmlSensitive: Set<Character> = ["\"", "&", "'", "+", "<", ">", "`"]

    static func writeDotnetString(_ text: String, into out: inout String) {
        out += "\""
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            switch scalar {
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            case "\\": out += "\\\\"
            default:
                if scalar.value >= 0x20, scalar.value <= 0x7E, !htmlSensitive.contains(Character(scalar)) {
                    out.unicodeScalars.append(scalar)
                } else {
                    // Java 按 UTF-16 码元逐个转义，补充平面字符拆成两个代理项
                    if scalar.value > 0xFFFF {
                        let offset = scalar.value - 0x10000
                        let high = 0xD800 + (offset >> 10)
                        let low = 0xDC00 + (offset & 0x3FF)
                        appendJavaUnicodeEscape(UInt32(high), into: &out)
                        appendJavaUnicodeEscape(UInt32(low), into: &out)
                    } else {
                        appendJavaUnicodeEscape(scalar.value, into: &out)
                    }
                }
            }
            i += 1
        }
        out += "\""
    }

    static func appendJavaUnicodeEscape(_ value: UInt32, into out: inout String) {
        let digits = Array("0123456789ABCDEF")
        out += "\\u"
        out.append(digits[Int((value >> 12) & 0xF)])
        out.append(digits[Int((value >> 8) & 0xF)])
        out.append(digits[Int((value >> 4) & 0xF)])
        out.append(digits[Int(value & 0xF)])
    }
}
