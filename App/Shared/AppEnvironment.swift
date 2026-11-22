import Foundation
import SwiftUI
import XiaoHaCore

/// 应用级单例容器，供 SwiftUI、后台任务与 App Intents 共用。
/// 刻意不加 @MainActor：核心层回调来自任意线程，这里统一用 onMain 收敛到主线程，
/// 避免在不同 Xcode / Swift 版本下出现隔离相关的编译差异。
final class AppEnvironment: ObservableObject, @unchecked Sendable {
    static let shared = AppEnvironment()

    @Published private(set) var status: VehicleStatus?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdateAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoggedIn = false
    @Published private(set) var vehicles: [GwmVehicle] = []
    @Published private(set) var sessionState: GwmRepository.SessionState = .loggedOut
    @Published private(set) var reauthMessage: String?
    @Published private(set) var alerts: [StatusAlertCenter.Alert] = []
    @Published private(set) var unread = 0
    @Published var progressText: String?
    @Published var banner: Banner?
    @Published var pendingTemp: Double = TempControl.defaultC
    @Published var tempZone: TempControl.Zone = .both
    @Published var fahrenheit = false
    @Published var runMinutes = VehicleAction.defaultRunMinutes
    @Published private(set) var pollEnabled = false

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    let alertCenter = StatusAlertCenter()
    private let settings = AppSettings()
    private let lock = NSRecursiveLock()
    private var _repository: GwmRepository?
    private var _executor: CommandExecutor?

    var repository: GwmRepository {
        lock.lock(); defer { lock.unlock() }
        if let existing = _repository { return existing }
        let prefs = GwmRepository.Preferences(
            pollEnabled: settings.pollEnabled,
            pollIntervalSeconds: settings.pollIntervalSeconds,
            remoteEnabled: settings.remoteEnabled,
            selectedVin: settings.selectedVin
        )
        let created = GwmRepository(store: GwmSecureStore(), preferences: prefs, alertCenter: alertCenter,
                                    emit: { [weak self] event in self?.handle(event) })
        _repository = created
        return created
    }

    var executor: CommandExecutor {
        lock.lock(); defer { lock.unlock() }
        if let existing = _executor { return existing }
        let created = CommandExecutor(repository: repository)
        _executor = created
        return created
    }

    private init() {
        pollEnabled = settings.pollEnabled
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func handle(_ event: GwmRepository.Event) {
        onMain { [weak self] in self?.apply(event) }
    }

    private func apply(_ event: GwmRepository.Event) {
        switch event {
        case let .loginStateChanged(loggedIn):
            isLoggedIn = loggedIn
            sessionState = repository.sessionState
        case let .reauthRequired(message):
            reauthMessage = message
            banner = Banner(text: message, isError: true)
        case let .refreshing(refreshing):
            isRefreshing = refreshing
        case let .statusUpdated(status, error):
            self.status = status
            lastError = error
            lastUpdateAt = repository.lastUpdateAt
            sessionState = repository.sessionState
            if let latest = repository.lastVehicles { vehicles = latest }
            if let vin = repository.selectedVin() { settings.selectedVin = vin }
            syncWidgetSnapshot()
        case let .alert(alert):
            alerts.append(alert)
            unread = alertCenter.unreadCount
            AlertNotifier.shared.notify(alert)
        }
    }

    /// 把最新状态写进 App Group，供桌面小组件读取。
    private func syncWidgetSnapshot() {
        let vin = repository.selectedVin()
        let vehicle = vehicles.first { $0.vin == vin }
        WidgetStore.save(WidgetSnapshot(status: status, vehicle: vehicle, updatedAt: lastUpdateAt))
        WidgetRefresh.reload()
    }

    func start() {
        repository.bootstrap()
        onMain { [weak self] in
            guard let self else { return }
            self.refreshSnapshot()
            if self.pollEnabled {
                BackgroundPoller.shared.startForegroundPolling()
                BackgroundPoller.shared.schedule()
            }
        }
    }

    func refreshSnapshot() {
        let snapshot = (
            repository.isLoggedIn,
            repository.sessionState,
            repository.currentStatus(),
            repository.lastUpdateAt,
            repository.lastVehicles ?? [],
            repository.isPollEnabled,
            repository.sessionMessage()
        )
        onMain { [weak self] in
            guard let self else { return }
            self.isLoggedIn = snapshot.0
            self.sessionState = snapshot.1
            self.status = snapshot.2
            self.lastUpdateAt = snapshot.3
            self.vehicles = snapshot.4
            self.pollEnabled = snapshot.5
            self.reauthMessage = snapshot.6
            if let vin = self.repository.selectedVin() { self.settings.selectedVin = vin }
        }
    }

    // MARK: - 登录

    func requestSmsCode(phone: String, completion: @escaping (Bool, String?) -> Void) {
        repository.requestSmsCode(phone) { [weak self] result in
            self?.onMain {
                switch result {
                case .success:
                    completion(true, nil)
                case let .failure(error):
                    self?.banner = Banner(text: "发送失败：" + error.friendlyMessage, isError: true)
                    completion(false, error.friendlyMessage)
                }
            }
        }
    }

    func login(phone: String, password: String, code: String, completion: @escaping (Bool, String?) -> Void) {
        let handler: GwmRepository.ResultCallback<[GwmVehicle]> = { [weak self] result in
            self?.onMain {
                guard let self else { return }
                switch result {
                case let .success(vehicles):
                    self.vehicles = vehicles
                    self.banner = Banner(text: "登录成功", isError: false)
                    self.refreshSnapshot()
                    if self.pollEnabled {
                        BackgroundPoller.shared.startForegroundPolling()
                    }
                    completion(true, nil)
                case let .failure(error):
                    self.banner = Banner(text: "登录失败：" + error.friendlyMessage, isError: true)
                    completion(false, error.friendlyMessage)
                }
            }
        }
        if !password.isEmpty {
            repository.loginPassword(phone: phone, password: password, completion: handler)
        } else {
            repository.loginSms(phone: phone, code: code, completion: handler)
        }
    }

    func logout() {
        repository.logout()
        settings.selectedVin = nil
        onMain { [weak self] in
            guard let self else { return }
            self.vehicles = []
            self.status = nil
            self.alerts = []
            self.unread = 0
        }
        refreshSnapshot()
        syncWidgetSnapshot()
    }

    // MARK: - 设置

    func setPollEnabled(_ enabled: Bool) {
        pollEnabled = enabled
        settings.pollEnabled = enabled
        repository.setPollEnabled(enabled)
        if enabled {
            BackgroundPoller.shared.startForegroundPolling()
            BackgroundPoller.shared.schedule()
        } else {
            BackgroundPoller.shared.cancel()
            banner = Banner(text: "已停止后台监控，不再推送状态提醒", isError: false)
        }
    }

    func setSelectedVin(_ vin: String) {
        repository.setSelectedVin(vin)
        settings.selectedVin = vin
        syncWidgetSnapshot()
    }

    func platformForSelectedVehicle() -> String {
        repository.platformOf(repository.selectedVin())
    }

    // MARK: - 车控

    func perform(_ action: VehicleAction, body: JSONValue? = nil, minutes: Int? = nil) {
        let label = (body?.value("temperature")?.asDouble).map { TempControl.labelOf($0) } ?? action.label
        let runMinutes = minutes ?? self.runMinutes
        onMain { [weak self] in
            self?.progressText = nil
            self?.banner = Banner(text: label + "：正在下发…", isError: false)
        }
        executor.run(action, body: body, minutes: runMinutes, onProgress: { [weak self] message in
            self?.onMain { self?.progressText = message }
        }, completion: { [weak self] result in
            self?.onMain {
                guard let self else { return }
                self.progressText = nil
                self.banner = Banner(text: result.message, isError: !result.success && !result.partial)
                self.alerts.append(.init(item: label, text: result.message, good: result.success))
                self.unread = self.alertCenter.unreadCount
                self.refreshSnapshot()
                if result.success { BackgroundRefresh.shared.request() }
            }
        })
    }

    func setTemp(_ newValue: Double) {
        pendingTemp = TempControl.normalize(newValue)
    }

    func clearUnread() {
        alertCenter.clearUnread()
        onMain { [weak self] in self?.unread = 0 }
    }
}

/// 轻量偏好存储。
final class AppSettings: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let pollKey = "poll_enabled"
    private let intervalKey = "poll_interval"
    private let remoteKey = "remote_enabled"
    private let vinKey = "selected_vin"

    var pollEnabled: Bool {
        get { defaults.object(forKey: pollKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: pollKey) }
    }

    var pollIntervalSeconds: Int {
        get { defaults.object(forKey: intervalKey) as? Int ?? GwmRepository.defaultInterval }
        set { defaults.set(newValue, forKey: intervalKey) }
    }

    var remoteEnabled: Bool {
        get { defaults.object(forKey: remoteKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: remoteKey) }
    }

    var selectedVin: String? {
        get { defaults.string(forKey: vinKey) }
        set { defaults.set(newValue, forKey: vinKey) }
    }
}
