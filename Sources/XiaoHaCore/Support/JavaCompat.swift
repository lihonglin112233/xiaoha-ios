import Foundation

/// 复刻 Java 侧的数值/字符串语义，避免 Swift 默认行为带来的偏差。
public enum JavaMath {
    /// Java 的 Math.round(float)：等于 floor(x + 0.5)。
    public static func round(_ value: Double) -> Int {
        Int((value + 0.5).rounded(.down))
    }

    /// Java 的 Math.rint：取最近偶数。
    public static func rint(_ value: Double) -> Double {
        value.rounded(.toNearestOrEven)
    }

    /// Java 的 (long) double 截断。
    public static func truncate(_ value: Double) -> Int64 {
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value.rounded(.towardZero))
    }

    /// Java 的 Double.toString 近似实现：整数值输出 "x.0"，指数部分格式化为 Java 风格。
    public static func doubleToString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        if value == rint(value), abs(value) < 1e7 {
            return String(truncate(value)) + ".0"
        }
        var text = "\(value)"
        if let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var mantissa = String(text[text.startIndex..<eIndex])
            var exponent = String(text[text.index(after: eIndex)...])
            if !mantissa.contains(".") { mantissa += ".0" }
            if exponent.hasPrefix("+") { exponent.removeFirst() }
            if !exponent.hasPrefix("-") { exponent = "+" + exponent }
            text = mantissa + "E" + exponent
        }
        return text
    }

    /// 左补零的整数格式化，等价 %0Nd。
    public static func pad(_ value: Int64, width: Int) -> String {
        var text = String(value)
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        while text.count < width { text = "0" + text }
        return negative ? "-" + text : text
    }

    /// 定点小数格式化，等价 String.format(Locale.ROOT, "%.Nf", x)。
    public static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

/// 复刻 Java 的 URLEncoder.encode(s, "UTF-8")（空格转 +），以及 GwmClient 的 urlEncode/urlEncodeFull。
public enum JavaURL {
    static let safe: Set<UInt8> = Set(Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.*".utf8))

    public static func encode(_ text: String) -> String {
        var out = String()
        for byte in Array(text.utf8) {
            if safe.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else if byte == 0x20 {
                out.append("+")
            } else {
                out.append("%")
                out += String(format: "%02X", Int(byte))
            }
        }
        return out
    }

    /// GwmClient.urlEncode：把 + 还原成 %20。
    public static func encodeSpacesAsPercent(_ text: String) -> String {
        encode(text).replacingOccurrences(of: "+", with: "%20")
    }

    /// GwmClient.urlEncodeFull：再转义 * 和 ~。
    public static func encodeFull(_ text: String) -> String {
        encodeSpacesAsPercent(text)
            .replacingOccurrences(of: "*", with: "%2A")
            .replacingOccurrences(of: "%7E", with: "~")
    }

    /// GwmCrypto.javaUrlEncode：与 encode 相同规则，供签名使用。
    public static func javaUrlEncode(_ text: String) -> String {
        encode(text)
    }

    static func isHex(_ c: Character) -> Bool {
        (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
    }

    /// GwmCrypto.urlDecode 的等价实现。
    public static func decode(_ text: String) -> String {
        let chars = Array(text)
        var out = [UInt8]()
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%", i + 2 < chars.count,
               isHex(chars[i + 1]), isHex(chars[i + 2]),
               let value = UInt8(String(chars[i + 1...i + 2]), radix: 16) {
                out.append(value)
                i += 3
                continue
            }
            out.append(contentsOf: Array(String(c).utf8))
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
