import Foundation

/// 用户可执行的车控动作，对齐原 APK 的 VehicleActions。
public enum VehicleAction: String, CaseIterable, Sendable {
    case lock = "LOCK"
    case unlock = "UNLOCK"
    case windowClose = "WINDOW_CLOSE"
    case whistle = "WHISTLE"
    case flash = "FLASH"
    case acOn = "AC_ON"
    case acOff = "AC_OFF"
    case defrostFront = "DEFROST_FRONT"
    case defrostRear = "DEFROST_REAR"
    case steerHeat = "STEER_HEAT"
    case engineStart = "ENGINE_START"
    case engineStop = "ENGINE_STOP"
    case acTempSet = "AC_TEMP_SET"

    /// 下发给车云平台的控制类型。
    public var controlType: String {
        switch self {
        case .lock: return GwmCommand.lock
        case .unlock: return GwmCommand.unlock
        case .windowClose: return "WINDOW_CLOSE"
        case .whistle: return "WHISTLE"
        case .flash: return "FLASH"
        case .acOn: return GwmCommand.acStart
        case .acOff: return GwmCommand.acStop
        case .defrostFront: return GwmCommand.defrostFrontStart
        case .defrostRear: return GwmCommand.defrostBackStart
        case .steerHeat: return GwmCommand.steerHeatStart
        case .engineStart: return "ENGINE_START"
        case .engineStop: return "ENGINE_STOP"
        case .acTempSet: return GwmCommand.acStart
        }
    }

    public var label: String {
        switch self {
        case .lock: return "锁车"
        case .unlock: return "解锁"
        case .windowClose: return "关车窗"
        case .whistle: return "鸣笛"
        case .flash: return "闪灯"
        case .acOn: return "开空调"
        case .acOff: return "关空调"
        case .defrostFront: return "前除霜"
        case .defrostRear: return "后除霜"
        case .steerHeat: return "方向盘加热"
        case .engineStart: return "远程启动"
        case .engineStop: return "远程熄火"
        case .acTempSet: return "调温"
        }
    }

    /// 需要车辆已启动的空调类动作。
    public var needsEngine: Bool {
        switch self {
        case .acOn, .acTempSet, .defrostFront, .defrostRear, .steerHeat: return true
        default: return false
        }
    }

    public static let defaultRunMinutes = 15
    public static let runMinuteOptions = [10, 15, 20, 30]

    /// 远程启动的命令体：operationTime（秒）与 runMinutes。
    public static func bodyOf(_ action: VehicleAction, minutes: Int) -> JSONValue? {
        guard action == .engineStart else { return nil }
        let clamped = max(1, min(30, minutes))
        return .object([
            ("operationTime", .int(clamped * 60)),
            ("runMinutes", .int(clamped)),
        ])
    }

    public static func acBodyOf(temperatureCelsius: Double?) -> JSONValue {
        TempControl.bodiesOf(temperatureCelsius ?? TempControl.defaultC, zone: .both)
    }

    public func step(temp: Double?, zone: TempControl.Zone = .both) -> OutcomeStep {
        switch self {
        case .lock:
            return OutcomeStep(controlType: controlType, label: label, probe: .locked)
        case .unlock:
            return OutcomeStep(controlType: controlType, label: label, probe: .unlocked)
        case .windowClose:
            return OutcomeStep(controlType: controlType, label: label, probe: .sideWindowsClosed)
        case .acOn:
            return OutcomeStep(controlType: controlType, label: label, probe: .acOn)
        case .acOff:
            return OutcomeStep(controlType: controlType, label: label, probe: .acOff)
        case .defrostFront:
            return OutcomeStep(controlType: controlType, label: label, probe: .frontDefrostOn)
        case .defrostRear:
            return OutcomeStep(controlType: controlType, label: label, probe: .rearDefrostOn)
        case .steerHeat:
            return OutcomeStep(controlType: controlType, label: label, probe: .steerHeatOn)
        case .engineStart:
            return OutcomeStep(controlType: controlType, label: label, probe: .engineRunning)
        case .engineStop:
            return OutcomeStep(controlType: controlType, label: label, probe: .engineOff)
        case .acTempSet:
            let target = temp ?? TempControl.defaultC
            return OutcomeStep(controlType: controlType, label: TempControl.labelOf(target), probe: .tempAt(TempControl.normalize(target)))
        case .whistle, .flash:
            return OutcomeStep(controlType: controlType, label: label, probe: .unverifiable)
        }
    }
}

/// 平台指令常量，对应 GwmClient 中的 CMD_*。
public enum GwmCommand {
    public static let lock = "VEHICLE_LOCK"
    public static let unlock = "VEHICLE_UNLOCK"
    public static let windowClose = "WINDOW_CLOSE"
    public static let whistle = "WHISTLE"
    public static let flash = "FLASH"
    public static let whistleFlash = "WHISTLE_FLASH"
    public static let engineStart = "ENGINE_START"
    public static let engineStop = "ENGINE_STOP"
    public static let skylightClose = "SKYLIGNT_CLOSE"
    public static let acStart = "AIR_CONDITIONER_START"
    public static let acStop = "AIR_CONDITIONER_STOP"
    public static let steerHeatStart = "STEERING_WHEEL_HEATING"
    public static let steerHeatStop = "STEERING_WHEEL_HEATLESS"
    public static let defrostFrontStart = "DEFROST_FRONT_START"
    public static let defrostFrontStop = "DEFROST_FRONT_STOP"
    public static let defrostBackStart = "DEFROST_BACK_START"
    public static let defrostBackStop = "DEFROST_BACK_STOP"
    public static let seatHeatStart = "SEAT_HEATING_START"
    public static let seatHeatStop = "SEAT_HEATING_STOP"
    public static let seatVentStart = "SEAT_VENTILATION_START"
    public static let seatVentStop = "SEAT_VENTILATION_STOP"

    /// 走 timely 接口的指令集合。
    static let timelyCommands: Set<String> = [whistle, flash, whistleFlash, acStart, acStop, steerHeatStart]
    static let timelyWithBody: Set<String> = [acStart]

    /// 走 AutoAI（gtsp）平台的指令码。
    static let autoAiCodes: [String: Int] = [
        unlock: 1,
        lock: 2,
        windowClose: 3,
        whistleFlash: 5,
        acStart: 6,
        acStop: 7,
        engineStart: 15,
        engineStop: 16,
        whistle: 19,
        flash: 20,
        skylightClose: 28,
    ]
}
