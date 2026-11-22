import Foundation

/// 结果校验探针，对应 CommandOutcome.Probe。返回 nil 表示该车型不回读此项。
public enum OutcomeProbe: Sendable {
    case locked
    case unlocked
    case windowsClosed
    case sideWindowsClosed
    case skylightClosed
    case engineRunning
    case engineOff
    case acOn
    case acOff
    case acAuto
    case frontDefrostOn
    case rearDefrostOn
    case steerHeatOn
    case acTempKnown
    case tempAt(Double)
    case trunkOpen
    case unverifiable

    public func read(_ status: VehicleStatus?) -> Bool? {
        guard let status else { return nil }
        switch self {
        case .locked: return status.doorsLocked
        case .unlocked: return status.doorsLocked.map { !$0 }
        case .windowsClosed: return !status.hasOpenWindow()
        case .sideWindowsClosed:
            if status.windowFrontLeft == nil, status.windowFrontRight == nil,
               status.windowRearLeft == nil, status.windowRearRight == nil {
                return nil
            }
            return !(status.windowFrontLeft == true || status.windowFrontRight == true
                     || status.windowRearLeft == true || status.windowRearRight == true)
        case .skylightClosed:
            guard let sunroof = status.sunroof else { return nil }
            return !sunroof
        case .engineRunning: return status.isEngineRunning()
        case .engineOff: return !status.isEngineRunning()
        case .acOn: return status.airConditioner
        case .acOff:
            guard let ac = status.airConditioner else { return nil }
            return !ac
        case .acAuto: return status.acAutoMode
        case .frontDefrostOn: return status.frontDefroster
        case .rearDefrostOn: return status.rearDefroster
        case .steerHeatOn: return status.steerWheelHeat
        case .acTempKnown: return status.acTempSet == nil ? nil : true
        case let .tempAt(target):
            guard let actual = status.acTempSet else { return nil }
            return abs(actual - target) <= 0.5009999871253967
        case .trunkOpen:
            guard let trunk = status.doorTrunk else { return nil }
            return trunk
        case .unverifiable: return nil
        }
    }
}

public struct OutcomeStep: Sendable {
    public let controlType: String?
    public let label: String
    public let probe: OutcomeProbe

    public init(controlType: String?, label: String, probe: OutcomeProbe) {
        self.controlType = controlType
        self.label = label
        self.probe = probe
    }
}

public enum OutcomeState: Sendable {
    case done
    case pending
    case unverifiable
}

/// 命令结果判定与文案，对应 CommandOutcome。
public enum CommandOutcome {
    public static func judge(_ step: OutcomeStep?, _ status: VehicleStatus?) -> OutcomeState {
        guard let step else { return .unverifiable }
        guard let value = step.probe.read(status) else { return .unverifiable }
        return value ? .done : .pending
    }

    public static func judgeAll(_ steps: [OutcomeStep], _ status: VehicleStatus?) -> OutcomeState {
        var hasPending = false
        var hasDone = false
        for step in steps {
            switch judge(step, status) {
            case .pending: hasPending = true
            case .done: hasDone = true
            case .unverifiable: break
            }
        }
        if hasPending { return .pending }
        return hasDone ? .done : .unverifiable
    }

    public static func done(_ steps: [OutcomeStep], _ status: VehicleStatus?) -> [OutcomeStep] {
        steps.filter { judge($0, status) == .done }
    }

    public static func pending(_ steps: [OutcomeStep], _ status: VehicleStatus?) -> [OutcomeStep] {
        steps.filter { judge($0, status) == .pending }
    }

    static func labels(_ steps: [OutcomeStep]) -> String {
        steps.map(\.label).joined(separator: "、")
    }

    static func detail(_ steps: [OutcomeStep], _ status: VehicleStatus?) -> String {
        let doneSteps = done(steps, status)
        return doneSteps.count <= 1 ? "" : "（\(labels(doneSteps))）"
    }

    /// 未在超时内完成时的反馈文案。
    public static func feedback(_ label: String, _ steps: [OutcomeStep], _ status: VehicleStatus?, _ timedOut: Bool) -> String {
        guard !steps.isEmpty else { return label + "：已下发" }
        if judgeAll(steps, status) == .done {
            return label + "成功" + detail(steps, status)
        }
        guard let status else { return label + "：车况暂时读不到" }
        let pendingSteps = pending(steps, status)
        let doneSteps = done(steps, status)
        let firstState = judge(steps[0], status)
        let firstDone = firstState == .done
        let firstUnverifiable = firstState == .unverifiable

        if !firstDone || doneSteps.isEmpty {
            if !firstUnverifiable || timedOut {
                return timedOut ? label + "未生效：车况没有变化，可能车没收到指令"
                              : label + "已下发，车况还没变化，等待车端执行…"
            }
            return label + "已下发（该车型不回读此项，无法确认是否生效）"
        }
        var text = label + "部分完成：" + labels(doneSteps) + "已完成"
        if !pendingSteps.isEmpty {
            text += "，但" + labels(pendingSteps) + "还没完成"
        }
        return text
    }

    /// 除主结果外还顺带完成的项目。
    public static func sideEffects(_ steps: [OutcomeStep], _ before: VehicleStatus?, _ after: VehicleStatus?) -> String {
        guard !steps.isEmpty, let before, let after else { return "" }
        var extras: [String] = []
        for step in steps.dropFirst() {
            guard let wasDone = step.probe.read(before), let isDone = step.probe.read(after) else { continue }
            if !wasDone && isDone { extras.append(step.label) }
        }
        return extras.isEmpty ? "" : "，另外还完成了" + extras.joined(separator: "、")
    }
}
