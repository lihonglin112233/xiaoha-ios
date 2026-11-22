import Foundation

/// 空调温度控制，对齐原 APK 的 TempControl。
public enum TempControl {
    public static let minC: Double = 17.0
    public static let maxC: Double = 31.0
    public static let stepC: Double = 0.5
    public static let defaultC: Double = 24.0
    public static let defaultDurationSeconds = 600
    static let allowStartEng = 1

    public enum Zone: String, Sendable {
        case both = "BOTH"
        case driver = "DRIVER"
        case passenger = "PASSENGER"

        public var label: String {
            switch self {
            case .driver: return "主驾"
            case .passenger: return "副驾"
            case .both: return "全车"
            }
        }

        public var next: Zone {
            switch self {
            case .both: return .driver
            case .driver: return .passenger
            case .passenger: return .both
            }
        }
    }

    public static func normalize(_ value: Double) -> Double {
        let clamped = min(maxC, max(minC, value))
        let rounded = (clamped / stepC).rounded() * stepC
        return (rounded * 10).rounded() / 10
    }

    public static func up(_ value: Double) -> Double { normalize(normalize(value) + 0.5) }
    public static func down(_ value: Double) -> Double { normalize(normalize(value) - 0.5) }
    public static func atMax(_ value: Double) -> Bool { normalize(value) >= maxC }
    public static func atMin(_ value: Double) -> Bool { normalize(value) <= minC }
    public static func inRange(_ value: Double) -> Bool { value >= 16.999 && value <= 31.001 }

    public static func format(_ value: Double, fahrenheit: Bool = false) -> String {
        let normalized = normalize(value)
        if fahrenheit {
            return JavaMath.fixed(normalized * 9.0 / 5.0 + 32.0, decimals: 0) + "°F"
        }
        let isInteger = abs(normalized - JavaMath.rint(normalized)) < 0.001
        return JavaMath.fixed(normalized, decimals: isInteger ? 0 : 1) + "°C"
    }

    public static func labelOf(_ value: Double) -> String {
        "调温至 " + format(value)
    }

    /// 空调命令体：allowStartEng + operationTime + temperature。
    public static func bodiesOf(_ value: Double, zone: Zone) -> JSONValue {
        let rounded = JavaMath.round(normalize(value))
        return .object([
            ("allowStartEng", .int(allowStartEng)),
            ("operationTime", .int(defaultDurationSeconds)),
            ("temperature", .int(rounded)),
        ])
    }

    public struct Verdict: Sendable {
        public let allowed: Bool
        public let message: String
    }

    public static func canSet(_ status: VehicleStatus?, _ value: Double) -> Verdict {
        if !inRange(value) {
            return Verdict(allowed: false, message: "温度超出可调范围（17~31℃）")
        }
        let hvac = HvacGuard.canTurnOn(status)
        return Verdict(allowed: hvac.allowed, message: hvac.message)
    }

    /// 温度是否可回读，用于结果提示。
    public static func responseOf(_ status: VehicleStatus?) -> (verifiable: Bool, note: String) {
        guard let status else { return (false, "车况还没拉到，无法验证温度") }
        return status.acTempSet == nil
            ? (false, "该车型不上报空调设定温度，只能确认已下发")
            : (true, "可验证")
    }
}
