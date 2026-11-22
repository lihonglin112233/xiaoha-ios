import Foundation

/// 自然语言车控指令解析，对齐原 APK 的 ChatCommandBridge。
public enum ChatCommandBridge {
    public struct Parsed: Equatable, Sendable {
        public let action: VehicleAction
        public let temp: Double?
        public let minutes: Int

        public init(action: VehicleAction, temp: Double? = nil, minutes: Int = 0) {
            self.action = action
            self.temp = temp
            self.minutes = minutes
        }

        public var description: String {
            var text = action.rawValue
            if let temp { text += " @\(JavaMath.doubleToString(temp))℃" }
            return text
        }
    }

    /// 与原实现一致：两位数 + 可选“度”。
    static func temp(_ text: String) -> Double? {
        let pattern = "(\\d{2})\\s*度?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range(at: 1), in: text),
                  let value = Int(text[matchRange]), value >= 16, value <= 32 else { continue }
            return Double(value)
        }
        return nil
    }

    static func hit(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    public static func parse(_ input: String) -> Parsed? {
        let text = input.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }

        if hit(text, ["关车窗", "关窗", "车窗关上", "车窗关闭"]) {
            return Parsed(action: .windowClose)
        }
        if hit(text, ["远程熄火", "熄火"]) {
            return Parsed(action: .engineStop)
        }
        if hit(text, ["远程启动", "启动发动机", "启动"]) {
            return Parsed(action: .engineStart, minutes: 15)
        }
        if hit(text, ["关空调"]) {
            return Parsed(action: .acOff)
        }
        if hit(text, ["开空调"]) {
            if let value = temp(text) {
                return Parsed(action: .acTempSet, temp: value)
            }
            return Parsed(action: .acOn)
        }
        if hit(text, ["前除霜"]) {
            return Parsed(action: .defrostFront)
        }
        if hit(text, ["后除霜"]) {
            return Parsed(action: .defrostRear)
        }
        if hit(text, ["方向盘加热"]) {
            return Parsed(action: .steerHeat)
        }
        if hit(text, ["鸣笛", "找车", "按喇叭"]) {
            return Parsed(action: .whistle)
        }
        if hit(text, ["闪灯", "闪一下"]) {
            return Parsed(action: .flash)
        }
        if hit(text, ["解锁", "开门"]) {
            return Parsed(action: .unlock)
        }
        if hit(text, ["锁车", "锁门", "上锁"]) {
            return Parsed(action: .lock)
        }
        if let value = temp(text) {
            return Parsed(action: .acTempSet, temp: value)
        }
        return nil
    }
}
