import Foundation

public enum HvacGuard {
    static let noStatus = "车况还没读到，无法确认车辆是否启动，暂时不能开空调"

    public struct Verdict: Sendable {
        public let allowed: Bool
        public let message: String
    }

    public static func canTurnOn(_ status: VehicleStatus?) -> Verdict {
        guard let status else { return Verdict(allowed: false, message: noStatus) }
        _ = status
        return Verdict(allowed: true, message: "可以远程开空调")
    }

    public static func canTurnOff(_ status: VehicleStatus?) -> Verdict {
        Verdict(allowed: true, message: "可以关空调")
    }

    public static func isVehicleStarted(_ status: VehicleStatus?) -> Bool {
        status?.isEngineRunning() ?? false
    }

    public static func hint(_ status: VehicleStatus?) -> String {
        guard let status else { return "车况未同步" }
        return isVehicleStarted(status)
            ? "车辆已启动 · 可远程控制空调"
            : "车辆未启动 · 可远程开启空调（会一并启动发动机）"
    }

    /// gtsp / navinfo 平台不开放除霜与方向盘加热。
    public static func platformSupportsAux(_ platform: String?) -> Bool {
        guard let platform, !platform.isEmpty else { return true }
        let lower = platform.lowercased()
        return !(lower.contains("gtsp") || lower.contains("navinfo"))
    }

    public static func platformSupportsHvac(_ platform: String?) -> Bool { true }

    public static func unsupportedPlatformText(_ platform: String?) -> String {
        "当前车机平台（\(platform ?? "未知")）未开放除霜/方向盘加热指令，可改用开空调调节车内温度"
    }
}

public enum EngineGuard {
    public static let minBatteryPercent: Double = 15.0
    public static let minBatteryVoltage: Double = 11.6

    public struct Verdict: Sendable {
        public let allowed: Bool
        public let needsConfirm: Bool
        public let message: String
    }

    public static func canStart(_ status: VehicleStatus?) -> Verdict {
        guard let status else {
            return Verdict(allowed: false, needsConfirm: false, message: "车况还没读到，无法确认车辆状态，暂时不能远程启动")
        }
        if status.engineState == nil {
            return Verdict(allowed: false, needsConfirm: false, message: "该车型没有上报启动状态，无法远程启动")
        }
        if status.isEngineRunning() {
            return Verdict(allowed: false, needsConfirm: false, message: "车辆已在\(status.engineText())，无需重复启动")
        }
        if status.hasOpenDoor() {
            return Verdict(allowed: true, needsConfirm: true, message: "有车门或后备箱未关闭，远程启动前请确认车内无人、周围安全")
        }
        if let battery = status.batteryPercent, battery < minBatteryPercent {
            return Verdict(allowed: false, needsConfirm: false,
                           message: "电量仅剩 \(JavaMath.fixed(battery, decimals: 0))%，低于 15%，不建议远程启动")
        }
        if let voltage = status.batteryVoltage, voltage < minBatteryVoltage {
            return Verdict(allowed: false, needsConfirm: false,
                           message: "蓄电池电压仅 \(JavaMath.fixed(voltage, decimals: 1))V，可能无法启动")
        }
        return Verdict(allowed: true, needsConfirm: false, message: "可以远程启动")
    }

    public static func canStop(_ status: VehicleStatus?) -> Verdict {
        guard let status else { return Verdict(allowed: true, needsConfirm: false, message: "可以远程熄火") }
        if status.engineState == nil || status.isEngineRunning() {
            return Verdict(allowed: true, needsConfirm: false, message: "可以远程熄火")
        }
        return Verdict(allowed: false, needsConfirm: false, message: "车辆当前已\(status.engineText())，无需熄火")
    }

    public static func hint(_ status: VehicleStatus?) -> String {
        guard let status else { return "车况未同步" }
        if status.engineState == nil { return "该车型不上报启动状态" }
        return status.isEngineRunning()
            ? status.engineText() + " · 可远程熄火"
            : "已" + status.engineText() + " · 可远程启动"
    }
}
