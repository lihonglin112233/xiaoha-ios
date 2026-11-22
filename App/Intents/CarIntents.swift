import AppIntents
import SwiftUI
import XiaoHaCore

/// 语音指令：对应 Android 的 ChatCommandBridge，可在「快捷指令 / Siri」里说「用车控」。
struct CarControlIntent: AppIntent {
    static var title: LocalizedStringResource = "车控指令"
    static var description = IntentDescription("用一句话控制车辆，例如“锁车”“开空调 24 度”。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "指令", description: "例如：锁车、解锁、开空调 24 度、远程启动")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let parsed = ChatCommandBridge.parse(text) else {
            return .result(dialog: "未识别到车控指令：\(text)")
        }
        let outcome = await CarIntentRunner.run(parsed)
        return .result(dialog: IntentDialog(stringLiteral: outcome))
    }

    static var parameterSummary: some ParameterSummary {
        Summary("对车辆执行 \(\.$text)")
    }
}

struct CarLockIntent: AppIntent {
    static var title: LocalizedStringResource = "锁车"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await CarIntentRunner.run(.init(action: .lock))))
    }
}

struct CarUnlockIntent: AppIntent {
    static var title: LocalizedStringResource = "解锁"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await CarIntentRunner.run(.init(action: .unlock))))
    }
}

struct CarAcOnIntent: AppIntent {
    static var title: LocalizedStringResource = "开空调"

    @Parameter(title: "温度", default: 24)
    var temperature: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral:
            await CarIntentRunner.run(.init(action: .acTempSet, temp: Double(temperature)))))
    }
}

struct CarEngineStartIntent: AppIntent {
    static var title: LocalizedStringResource = "远程启动"

    @Parameter(title: "运行分钟", default: 15)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral:
            await CarIntentRunner.run(.init(action: .engineStart, minutes: minutes))))
    }
}

struct CarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CarLockIntent(), phrases: ["用车控锁车", "让小哈锁车"],
                    shortTitle: "锁车", systemImageName: "lock.fill")
        AppShortcut(intent: CarUnlockIntent(), phrases: ["用车控解锁"],
                    shortTitle: "解锁", systemImageName: "lock.open.fill")
        AppShortcut(intent: CarAcOnIntent(), phrases: ["用车控开空调"],
                    shortTitle: "开空调", systemImageName: "snowflake")
        AppShortcut(intent: CarEngineStartIntent(), phrases: ["用车控远程启动"],
                    shortTitle: "远程启动", systemImageName: "power")
    }
}

/// 意图执行桥：等待一次完整结果，避免 Siri 立刻回「完成」但实际没下发。
enum CarIntentRunner {
    static func run(_ parsed: ChatCommandBridge.Parsed) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let env = AppEnvironment.shared
                guard env.isLoggedIn else {
                    continuation.resume(returning: "小哈车控未登录")
                    return
                }
                let body: JSONValue? = {
                    if parsed.action == .acTempSet, let temp = parsed.temp {
                        return TempControl.bodiesOf(temp, zone: .both)
                    }
                    if parsed.action == .acOn {
                        return TempControl.bodiesOf(TempControl.defaultC, zone: .both)
                    }
                    return nil
                }()
                env.perform(parsed.action, body: body, minutes: parsed.minutes == 0 ? nil : parsed.minutes)
                // 等车况校验流程给出结论（最长 60 秒）
                let deadline = Date().addingTimeInterval(60)
                Task {
                    while Date() < deadline {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        let text: String? = await MainActor.run { env.banner?.text }
                        if let text, text.contains("成功") || text.contains("失败")
                            || text.contains("未生效") || text.contains("已下发") || text.contains("暂时读不到") {
                            continuation.resume(returning: text)
                            return
                        }
                    }
                    let fallback: String = await MainActor.run { env.banner?.text ?? "已提交，请在 App 内查看结果" }
                    continuation.resume(returning: fallback)
                }
            }
        }
    }
}
