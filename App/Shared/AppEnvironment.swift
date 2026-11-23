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

    /// 登录/恢复后把策略应用到当前 client。
    func applyStrategyToClient() {
        repository.setHvacStrategy(hvacStrategy)
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
            repository.sessionMessage
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
            self.syncWidgetSnapshot()
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

    /// 自定义车况刷新间隔（秒）。
    var refreshIntervalSeconds: Int {
        get { settings.pollIntervalSeconds }
        set {
            settings.pollIntervalSeconds = max(GwmRepository.minInterval, min(3600, newValue))
            repository.setPollIntervalSeconds(settings.pollIntervalSeconds)
            BackgroundPoller.shared.restartTimer(interval: TimeInterval(settings.pollIntervalSeconds))
        }
    }

    /// gtsp 通道的空调策略（dedicatedCodes=原APK的6/7，engineFallback=远程启动/熄火）
    var hvacStrategy: GwmClient.HvacStrategy {
        get { GwmClient.HvacStrategy(rawValue: settings.hvacStrategyRaw) ?? .dedicatedCodes }
        set {
            settings.hvacStrategyRaw = newValue.rawValue
            repository.setHvacStrategy(newValue)
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
        // 显示真实下发的 controlType 与指令码，便于区分"点了什么"和"实际发了什么"
        let wire = Self.wireDescription(action)
        onMain { [weak self] in
            self?.progressText = nil
            self?.banner = Banner(text: label + "：正在下发（" + wire + "）", isError: false)
        }
        executor.run(action, body: body, minutes: runMinutes, onProgress: { [weak self] message in
            self?.onMain { self?.progressText = message }
        }, completion: { [weak self] result in
            self?.onMain {
                guard let self else { return }
                self.progressText = nil
                let wire = result.controlType.map { " [" + $0 + "]" } ?? ""
                self.banner = Banner(text: result.message + wire,
                                     isError: !result.success && !result.partial)
                self.alerts.append(.init(item: label, text: result.message, good: result.success))
                self.unread = self.alertCenter.unreadCount
                self.refreshSnapshot()
                if result.success { BackgroundRefresh.shared.request() }
            }
        })
    }

    /// 形如 "VEHICLE_UNLOCK / cmdCode 1" 或 "VEHICLE_LOCK / T5"，用于自证下发内容。
    static func wireDescription(_ action: VehicleAction) -> String {
        let controlType = action.controlType
        if let code = GwmCommand.autoAiCodes[controlType] {
            return controlType + " / cmdCode " + String(code)
        }
        return controlType + " / T5"
    }

    /// 定位状态说明：让用户/我能直接看出是"未上报"还是"解析失败"。
    var locationStatusText: String {
        guard isLoggedIn else { return "登录后显示" }
        guard let status else { return "车况未同步" }
        if status.hasCoordinate { return "已获取" }
        let raw = repository.lastRawStatus ?? ""
        let hasLatKey = raw.range(of: "lat", options: .caseInsensitive) != nil
        let hasLonKey = raw.range(of: "lon", options: .caseInsensitive) != nil
            || raw.range(of: "lng", options: .caseInsensitive) != nil
        if hasLatKey || hasLonKey {
            return "报文含坐标字段但未解析成功，请复制原始车况反馈"
        }
        return "该车型未上报定位"
    }

    func setTemp(_ newValue: Double) {
        pendingTemp = TempControl.normalize(newValue)
    }

    func clearUnread() {
        alertCenter.clearUnread()
        onMain { [weak self] in self?.unread = 0 }
    }

    /// 导出云端原始车况报文：用于核对真实字段名（例如定位字段到底叫什么）。
    /// 会做脱敏：去掉 VIN 之外的个人标识不涉及，但坐标等业务数据保留以便核对。
    func rawStatusReport() -> String {
        var lines: [String] = []
        lines.append("=== 小哈车控 车况诊断 ===")
        lines.append("时间: " + ISO8601DateFormatter().string(from: Date()))
        lines.append("已登录: \(isLoggedIn)")
        lines.append("平台: \(platformForSelectedVehicle())")
        lines.append("车辆: \(repository.selectedVin() ?? "-")")
        lines.append("App Group: \(WidgetStore.diagnostics())")
        lines.append("最近更新: \(lastUpdateAt.map { ISO8601DateFormatter().string(from: $0) } ?? "无")")
        lines.append("")
        lines.append("=== 解析后定位 ===")
        if let status {
            lines.append("latitude=\(status.latitude.map { String($0) } ?? "nil")")
            lines.append("longitude=\(status.longitude.map { String($0) } ?? "nil")")
            lines.append("positionTime=\(status.positionTime ?? "nil")")
            lines.append("hasCoordinate=\(status.hasCoordinate)")
        } else {
            lines.append("尚无车况")
        }
        lines.append("")
        lines.append("=== 云端原始报文 ===")
        lines.append(repository.lastRawStatus ?? "（尚未拉取）")
        return lines.joined(separator: "\n")
    }

    /// 点击时立即拉取一次云端原始报文并复制，保证内容是最新的真实数据。
    func copyRawStatusReport() {
        banner = Banner(text: "正在拉取云端车况…", isError: false)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.repository.fetchRawStatusNow()
            self.onMain {
                switch result {
                case let .success(raw):
                    let text = self.buildReport(raw: raw)
                    UIPasteboard.general.string = text
                    self.banner = Banner(text: "原始车况已复制（\(raw.count) 字符）", isError: false)
                case let .failure(error):
                    UIPasteboard.general.string = self.buildReport(raw: nil)
                    self.banner = Banner(text: "拉取失败：" + error.friendlyMessage + "（已复制诊断）",
                                         isError: true)
                }
                self.syncWidgetSnapshot()
            }
        }
    }

    private func buildReport(raw: String?) -> String {
        var lines: [String] = []
        lines.append("=== 小哈车控 车况诊断 ===")
        lines.append("时间: " + ISO8601DateFormatter().string(from: Date()))
        lines.append("已登录: \(isLoggedIn)")
        lines.append("平台: \(platformForSelectedVehicle())")
        lines.append("车辆: \(repository.selectedVin() ?? "-")")
        lines.append("App Group: \(WidgetStore.diagnostics())")
        lines.append("")
        lines.append("=== 解析后定位 ===")
        if let status {
            lines.append("hasCoordinate=\(status.hasCoordinate)")
            lines.append("latitude=\(status.latitude.map { String($0) } ?? "nil")")
            lines.append("longitude=\(status.longitude.map { String($0) } ?? "nil")")
            lines.append("positionTime=\(status.positionTime ?? "nil")")
        } else {
            lines.append("尚无车况")
        }
        lines.append("")
        let rawText = raw ?? repository.lastRawStatus
        if let rawText, let parsed = JSONParser.parse(rawText) {
            let paths = VehicleStatus.keyPaths(parsed)
            // 只列出疑似坐标/时间相关路径，避免刷屏
            let interesting = paths.filter { path in
                let lower = path.lowercased()
                return lower.contains("lat") || lower.contains("lon") || lower.contains("lng")
                    || lower.contains("gps") || lower.contains("posit") || lower.contains("time")
            }
            lines.append("=== 疑似坐标/时间字段（共 \(paths.count) 个键）===")
            lines.append(interesting.isEmpty ? "（未发现任何坐标类字段）" : interesting.joined(separator: "\n"))
            lines.append("")
        }
        lines.append("=== 云端原始报文 ===")
        lines.append(rawText ?? "（拉取失败或尚未拉取）")
        return lines.joined(separator: "\n")
    }

    func clearAlerts() {
        alertCenter.clearUnread()
        onMain { [weak self] in
            self?.alerts.removeAll()
            self?.unread = 0
        }
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

    var hvacStrategyRaw: String {
        get { defaults.string(forKey: "hvac_strategy") ?? GwmClient.HvacStrategy.dedicatedCodes.rawValue }
        set { defaults.set(newValue, forKey: "hvac_strategy") }
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
