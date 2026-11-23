import Foundation

/// 命令编排与结果校验，对齐原 APK 的 CommandExecutor。
public final class CommandExecutor: @unchecked Sendable {
    public struct Result: Sendable {
        public let success: Bool
        public let partial: Bool
        public let message: String
        public let steps: [OutcomeStep]
        public let verified: Bool

        public init(success: Bool, partial: Bool, message: String, steps: [OutcomeStep], verified: Bool) {
            self.success = success
            self.partial = partial
            self.message = message
            self.steps = steps
            self.verified = verified
        }
    }

    public struct Progress: Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public typealias Callback = @Sendable (Result) -> Void
    public typealias ProgressHandler = @Sendable (String) -> Void

    /// 默认节奏；测试可注入更短的值。
    public struct Timing: Sendable {
        public var verifyInterval: TimeInterval
        public var verifyTimeout: TimeInterval
        public var stepGapOnSuccess: TimeInterval
        public var stepGapOnFailure: TimeInterval
        public var maxIterationsBeforeUnverifiable: Int

        public init(verifyInterval: TimeInterval = 4, verifyTimeout: TimeInterval = 48,
                    stepGapOnSuccess: TimeInterval = 1.2, stepGapOnFailure: TimeInterval = 0.8,
                    maxIterationsBeforeUnverifiable: Int = 2) {
            self.verifyInterval = verifyInterval
            self.verifyTimeout = verifyTimeout
            self.stepGapOnSuccess = stepGapOnSuccess
            self.stepGapOnFailure = stepGapOnFailure
            self.maxIterationsBeforeUnverifiable = maxIterationsBeforeUnverifiable
        }
    }

    private let repository: GwmRepository
    private let now: @Sendable () -> Date
    private let timing: Timing

    public init(repository: GwmRepository, timing: Timing = Timing(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository
        self.timing = timing
        self.now = now
    }

    /// 记录一次真实下发的 controlType，便于上层/测试核对顺序。
    public private(set) var dispatchedControlTypes: [String] = []
    /// 最近一次真实下发的 controlType（供界面展示，证明没串指令）。
    public private(set) var lastDispatchedControlType: String?

    static func isTempStep(_ step: OutcomeStep) -> Bool {
        step.label.hasPrefix("调温至")
    }

    static func tempOf(_ body: JSONValue?) -> Double? {
        body?.value("temperature")?.asDouble
    }

    static func zoneOf(_ body: JSONValue?) -> TempControl.Zone? {
        guard let raw = body?.value("zone")?.asString else { return nil }
        return TempControl.Zone(rawValue: raw)
    }

    static func labelOf(_ steps: [OutcomeStep], _ controlType: String, _ index: Int) -> String {
        if let match = steps.first(where: { $0.controlType == controlType }) { return match.label }
        return index < steps.count ? steps[index].label : controlType
    }

    /// 入口：按动作准备指令序列，逐条下发后校验车况。
    public func run(_ action: VehicleAction, body: JSONValue? = nil, minutes: Int = VehicleAction.defaultRunMinutes,
                    onProgress: ProgressHandler? = nil, completion: @escaping Callback) {
        var controlTypes: [String] = []
        var bodies: [JSONValue?] = []
        var steps: [OutcomeStep] = []
        let before = repository.currentStatus()

        if action.needsEngine {
            let verdict = HvacGuard.canTurnOn(before)
            if !verdict.allowed {
                completion(Result(success: false, partial: false, message: verdict.message, steps: [], verified: false))
                return
            }
        }
        if action == .engineStart {
            let verdict = EngineGuard.canStart(before)
            if !verdict.allowed {
                completion(Result(success: false, partial: false, message: verdict.message, steps: [], verified: false))
                return
            }
        } else if action == .engineStop {
            let verdict = EngineGuard.canStop(before)
            if !verdict.allowed {
                completion(Result(success: false, partial: false, message: verdict.message, steps: [], verified: false))
                return
            }
        }

        controlTypes.append(action.controlType)
        steps.append(action.step(temp: Self.tempOf(body), zone: Self.zoneOf(body) ?? .both))

        if action == .engineStart {
            var commandBody = VehicleAction.bodyOf(.engineStart, minutes: minutes) ?? .object([])
            if let body, let pairs = body.asObject {
                commandBody = .object((commandBody.asObject ?? []) + pairs)
            }
            bodies.append(commandBody)
        } else {
            var effective = body
            if action == .acOn {
                var acBody = VehicleAction.acBodyOf(temperatureCelsius: Self.tempOf(body))
                if let body, let pairs = body.asObject {
                    acBody = .object((acBody.asObject ?? []) + pairs)
                }
                effective = acBody
            }
            bodies.append(effective)

            if action == .lock {
                var extraParts: [String] = []
                if let before {
                    if OutcomeProbe.sideWindowsClosed.read(before) != true {
                        controlTypes.append("WINDOW_CLOSE")
                        bodies.append(nil)
                        steps.append(OutcomeStep(controlType: "WINDOW_CLOSE", label: "关车窗", probe: .sideWindowsClosed))
                        extraParts.append("车窗")
                    }
                    if before.sunroof == true {
                        controlTypes.append(GwmCommand.skylightClose)
                        bodies.append(nil)
                        steps.append(OutcomeStep(controlType: GwmCommand.skylightClose, label: "关天窗", probe: .skylightClosed))
                        extraParts.append("天窗")
                    }
                } else {
                    controlTypes.append("WINDOW_CLOSE")
                    bodies.append(nil)
                    steps.append(OutcomeStep(controlType: "WINDOW_CLOSE", label: "关车窗", probe: .sideWindowsClosed))
                    controlTypes.append(GwmCommand.skylightClose)
                    bodies.append(nil)
                    steps.append(OutcomeStep(controlType: GwmCommand.skylightClose, label: "关天窗", probe: .skylightClosed))
                }
                if !extraParts.isEmpty, before != nil {
                    onProgress?("检测到" + extraParts.joined(separator: "、") + "未关闭，一并下发")
                }
            }
        }

        sendSequentially(controlTypes, bodies, steps, before, 0, onProgress: onProgress, completion: completion)
    }

    private func sendSequentially(_ controlTypes: [String], _ bodies: [JSONValue?], _ steps: [OutcomeStep],
                                  _ before: VehicleStatus?, _ index: Int,
                                  onProgress: ProgressHandler?, completion: @escaping Callback) {
        guard index < controlTypes.count else {
            verify(steps, before, completion)
            return
        }
        let controlType = controlTypes[index]
        let label = Self.labelOf(steps, controlType, index)
        dispatchedControlTypes.append(controlType)
        lastDispatchedControlType = controlType
        if index > 0 {
            onProgress?("正在下发：" + label + "…")
        }
        repository.sendCommand(controlType, body: bodies[index]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(self.timing.stepGapOnSuccess * 1_000_000_000))
                    self.sendSequentially(controlTypes, bodies, steps, before, index + 1,
                                          onProgress: onProgress, completion: completion)
                }
            case let .failure(error):
                if index == 0 {
                    completion(Result(success: false, partial: false,
                                      message: steps[0].label + "下发失败：" + error.friendlyMessage,
                                      steps: steps, verified: false))
                    return
                }
                onProgress?(label + "下发失败，继续校验其他项")
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(self.timing.stepGapOnFailure * 1_000_000_000))
                    self.sendSequentially(controlTypes, bodies, steps, before, index + 1,
                                          onProgress: onProgress, completion: completion)
                }
            }
        }
    }

    private func verify(_ steps: [OutcomeStep], _ before: VehicleStatus?, _ completion: @escaping Callback) {
        tick(steps, before, completion, start: now(), iteration: 0)
    }

    private func tick(_ steps: [OutcomeStep], _ before: VehicleStatus?, _ completion: @escaping Callback,
                      start: Date, iteration: Int) {
        repository.refreshNow()
        let interval = timing.verifyInterval
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            self?.evaluate(steps, before, completion, start: start, iteration: iteration)
        }
    }

    func evaluate(_ steps: [OutcomeStep], _ before: VehicleStatus?, _ completion: @escaping Callback,
                  start: Date, iteration: Int) {
        let current = repository.currentStatus()
        let state = CommandOutcome.judgeAll(steps, current)
        let elapsed = now().timeIntervalSince(start)
        let label = steps.isEmpty ? "" : steps[0].label

        if state == .done {
            completion(Result(success: true, partial: false,
                              message: label + "成功" + CommandOutcome.sideEffects(steps, before, current),
                              steps: steps, verified: true))
            return
        }
        if state == .unverifiable, iteration >= timing.maxIterationsBeforeUnverifiable {
            let suffix = steps.first.map(Self.isTempStep) == true
                ? "（该车型不回读设定温度，无法确认是否生效）"
                : "（该车型无状态可校验）"
            completion(Result(success: true, partial: false, message: label + "：指令已下发" + suffix,
                              steps: steps, verified: false))
            return
        }
        if elapsed > timing.verifyTimeout {
            let partial = !CommandOutcome.done(steps, current).isEmpty
            completion(Result(success: false, partial: partial,
                              message: CommandOutcome.feedback(label, steps, current, true),
                              steps: steps, verified: false))
            return
        }
        tick(steps, before, completion, start: start, iteration: iteration + 1)
    }
}
