import SwiftUI
import UIKit
import UserNotifications
import XiaoHaCore

@main
struct XiaoHaCarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            ControlView()
                .environmentObject(env)
                .task {
                    AlertNotifier.shared.requestAuthorization()
                    env.start()
                }
                .onOpenURL { url in
                    handle(url)
                }
        }
    }

    /// 小组件按钮通过深链唤起 App，立即执行对应动作。
    private func handle(_ url: URL) {
        guard let link = WidgetDeepLink.parse(url) else { return }
        env.handleWidgetAction(link)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundPoller.shared.register()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundPoller.shared.stopForegroundPolling()
        if UserDefaults.standard.bool(forKey: "poll_enabled") {
            BackgroundPoller.shared.schedule()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if UserDefaults.standard.bool(forKey: "poll_enabled") {
            BackgroundPoller.shared.startForegroundPolling()
        }
        Task { @MainActor in
            AppEnvironment.shared.refreshSnapshot()
            AppEnvironment.shared.repository.refreshNow()
        }
    }
}
