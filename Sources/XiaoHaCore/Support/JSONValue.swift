import Foundation

/// 保序 JSON 值模型，对应 Java 侧的 LinkedHashMap/ArrayList 语义。
/// 解析规则与原 APK 的 JsonLite 一致：所有数字解析为 Double，未知字面量按数字处理。
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (index, pair) in a.enumerated() where pair.0 != b[index].0 || pair.1 != b[index].1 {
                return false
            }
            return true
        default: return false
        }
    }

    // MARK: - 访问器

    public var asObject: [(String, JSONValue)]? {
        if case let .object(pairs) = self { return pairs }
        return nil
    }

    public var asArray: [JSONValue]? {
        if case let .array(items) = self { return items }
        return nil
    }

    public var asString: String? {
        switch self {
        case let .string(s): return s
        case let .number(n):
            // Java valueToStr：整数值的 Double 输出为整数
            if n == JavaMath.rint(n), abs(n) < 9.0e15 { return String(JavaMath.truncate(n)) }
            return JavaMath.doubleToString(n)
        case let .bool(b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var asBool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var asDouble: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    public func value(_ key: String) -> JSONValue? {
        guard case let .object(pairs) = self else { return nil }
        for (k, v) in pairs where k == key { return v }
        return nil
    }

    /// 大小写不敏感查找，对应 Java 的 ciProp。
    public func valueIgnoringCase(_ key: String) -> JSONValue? {
        guard case let .object(pairs) = self else { return nil }
        let target = key.lowercased()
        for (k, v) in pairs where k.lowercased() == target { return v }
        return nil
    }

    /// 对应 Java 的 ciString：取字符串，空串视为 nil。
    public func stringIgnoringCase(_ key: String) -> String? {
        guard let value = valueIgnoringCase(key) else { return nil }
        let text = value.asString ?? ""
        return text.isEmpty ? nil : text
    }

    public mutating func set(_ key: String, _ newValue: JSONValue) {
        guard case var .object(pairs) = self else { return }
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[index].1 = newValue
        } else {
            pairs.append((key, newValue))
        }
        self = .object(pairs)
    }

    public func removingKey(_ key: String) -> JSONValue {
        guard case let .object(pairs) = self else { return self }
        return .object(pairs.filter { $0.0 != key })
    }

    // MARK: - 构造便捷方法

    public static func pairs(_ items: [(String, JSONValue)]) -> JSONValue {
        .object(items)
    }

    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }

    public static func optionalString(_ value: String?) -> JSONValue {
        value.map { .string($0) } ?? .null
    }
}

// MARK: - 解析（等价 JsonLite）

public enum JSONParser {
    public static func parse(_ text: String?) -> JSONValue? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var parser = Parser(source: Array(trimmed.unicodeScalars))
        return parser.readValueLenient()
    }

    /// 严格模式：解析失败返回 nil（区分"非法 JSON"与"合法但不是对象"）。
    public static func parseStrict(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var parser = Parser(source: Array(trimmed.unicodeScalars))
        do {
            return try parser.readValue()
        } catch {
            return nil
        }
    }

    struct Parser {
        let source: [UnicodeScalar]
        var pos = 0

        init(source: [UnicodeScalar]) {
            self.source = source
        }

        func peek() -> UnicodeScalar? {
            pos < source.count ? source[pos] : nil
        }

        mutating func skipWhitespace() {
            while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" || c.value == 0xFEFF {
                pos += 1
            }
        }

        /// 与 Java 版一致：解析失败不抛异常，尽量返回已解析内容。
        mutating func readValueLenient() -> JSONValue {
            do {
                return try readValue()
            } catch {
                return .null
            }
        }

        mutating func expect(_ literal: String) throws {
            let chars = Array(literal.unicodeScalars)
            guard pos + chars.count <= source.count else { throw ParseError.bad }
            for (i, c) in chars.enumerated() where source[pos + i] != c {
                throw ParseError.bad
            }
            pos += chars.count
        }

        mutating func readValue() throws -> JSONValue {
            skipWhitespace()
            guard let c = peek() else { throw ParseError.bad }
            switch c {
            case "\"": return .string(try readString())
            case "[": return try readArray()
            case "{": return try readObject()
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return .number(try readNumber())
            }
        }

        mutating func readNumber() throws -> Double {
            let start = pos
            while let c = peek(), (c >= "0" && c <= "9") || c == "-" || c == "+" || c == "." || c == "e" || c == "E" {
                pos += 1
            }
            let raw = String(String.UnicodeScalarView(source[start..<pos]))
            guard let value = Double(raw) else { throw ParseError.bad }
            return value
        }

        mutating func readString() throws -> String {
            pos += 1
            var out = String.UnicodeScalarView()
            while pos < source.count {
                let c = source[pos]
                pos += 1
                if c == "\"" { return String(out) }
                if c != "\\" {
                    out.append(c)
                    continue
                }
                guard pos < source.count else { throw ParseError.bad }
                let esc = source[pos]
                pos += 1
                switch esc {
                case "/": out.append("/")
                case "b": out.append(UnicodeScalar(8))
                case "f": out.append(UnicodeScalar(12))
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard pos + 4 <= source.count else { throw ParseError.bad }
                    let hex = String(String.UnicodeScalarView(source[pos..<(pos + 4)]))
                    guard let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) else { throw ParseError.bad }
                    out.append(scalar)
                    pos += 4
                default:
                    out.append(esc)
                }
            }
            throw ParseError.bad
        }

        mutating func readArray() throws -> JSONValue {
            pos += 1
            skipWhitespace()
            var items: [JSONValue] = []
            if peek() == "]" { pos += 1; return .array(items) }
            while true {
                items.append(try readValue())
                skipWhitespace()
                guard let sep = peek() else { throw ParseError.bad }
                pos += 1
                if sep == "]" { return .array(items) }
                if sep != "," { throw ParseError.bad }
            }
        }

        mutating func readObject() throws -> JSONValue {
            pos += 1
            skipWhitespace()
            var pairs: [(String, JSONValue)] = []
            if peek() == "}" { pos += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard peek() == "\"" else { throw ParseError.bad }
                let key = try readString()
                skipWhitespace()
                guard peek() == ":" else { throw ParseError.bad }
                pos += 1
                pairs.append((key, try readValue()))
                skipWhitespace()
                guard let sep = peek() else { throw ParseError.bad }
                pos += 1
                if sep == "}" { return .object(pairs) }
                if sep != "," { throw ParseError.bad }
            }
        }
    }

    enum ParseError: Error { case bad }
}
