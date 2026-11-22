import Foundation
import BackgroundTasks
import XiaoHaCore
#if canImport(UIKit)
import UIKit
#endif

/// 后台轮询：iOS 不允许常驻前台服务，用 BGAppRefreshTask + 前台定时器组合
/// 对应 Android 的 VehiclePollService。
final class BackgroundPoller {
    static let shared = BackgroundPoller()
    static let taskIdentifier = "com.xiaoha.car.refresh"

    private var foregroundTimer: Timer?

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(refreshTask)
        }
    }

    /// 回到前台时启动短周期定时器，退到后台后转交 BGTask。
    func startForegroundPolling() {
        guard foregroundTimer == nil else { return }
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            AppEnvironment.shared.repository.refreshNow()
        }
    }

    func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        stopForegroundPolling()
    }

    private func handle(_ task: BGAppRefreshTask) {
        // 先排下一次，避免链断
        schedule()
        let refresh = Task {
            await AppEnvironment.shared.repository.pollOnce()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            refresh.cancel()
        }
    }
}

#if canImport(UserNotifications)
import UserNotifications
#endif

/// 状态提醒的本地通知，对应 Android 的 StatusAlertCenter 通知部分。
final class AlertNotifier {
    static let shared = AlertNotifier()
    private let center = UNUserNotificationCenter.current()
    private let channel = "doro_status_alerts"

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(_ alert: StatusAlertCenter.Alert) {
        let content = UNMutableNotificationContent()
        content.title = "状态提醒"
        content.body = alert.item + "：" + alert.text
        content.sound = alert.good ? nil : .default
        let request = UNNotificationRequest(identifier: "\(alert.item)-\(UUID().uuidString)",
                                           content: content, trigger: nil)
        center.add(request)
    }

}

/// 前台刷新（原实现远控成功后连刷多次以等待车端执行）。
final class BackgroundRefresh {
    static let shared = BackgroundRefresh()
    private let queue = [3.0, 6.0, 10.0, 15.0, 20.0, 25.0, 30.0]

    func request() {
        for delay in queue {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                AppEnvironment.shared.repository.refreshNow()
            }
        }
    }
}
