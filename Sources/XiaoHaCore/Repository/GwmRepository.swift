import Foundation

/// 车辆仓储层：登录、会话恢复、轮询与状态广播，对齐原 APK 的 GwmRepository。
public final class GwmRepository: @unchecked Sendable {
    public static let defaultInterval = 60
    public static let minInterval = 30
    static let maxBackoff: TimeInterval = 600

    public enum SessionState: String, Sendable {
        case loggedOut
        case restoring
        case active
        case expired
    }

    public struct Preferences: Sendable {
        public var pollEnabled: Bool
        public var pollIntervalSeconds: Int
        public var remoteEnabled: Bool
        public var selectedVin: String?

        public init(pollEnabled: Bool = true, pollIntervalSeconds: Int = GwmRepository.defaultInterval,
                    remoteEnabled: Bool = true, selectedVin: String? = nil) {
            self.pollEnabled = pollEnabled
            self.pollIntervalSeconds = pollIntervalSeconds
            self.remoteEnabled = remoteEnabled
            self.selectedVin = selectedVin
        }
    }

    public enum Event: Sendable {
        case loginStateChanged(Bool)
        case reauthRequired(String)
        case refreshing(Bool)
        case statusUpdated(VehicleStatus?, String?)
        case alert(StatusAlertCenter.Alert)
    }

    public typealias ResultCallback<T> = @Sendable (Result<T, GwmError>) -> Void

    private let store: GwmSecureStore
    private let injectedClient: GwmClient?
    private var client: GwmClient?
    private var preferences: Preferences
    private(set) public var lastStatus: VehicleStatus?
    /// 最近一次 getLastStatus 的原始 JSON（未裁剪、未解析），用于核对云端真实字段名。
    private(set) public var lastRawStatus: String?
    private(set) public var lastError: String?
    private(set) public var lastUpdateAt: Date?
    private(set) public var lastVehicles: [GwmVehicle]?
    private(set) public var sessionState: SessionState = .loggedOut
    private(set) public var sessionMessage: String?
    private var consecutiveFailures = 0
    private var destroyed = false
    private var pollTask: Task<Void, Never>?
    private var polling = false
    private let alertCenter: StatusAlertCenter
    private let emitter: @Sendable (Event) -> Void
    private let now: @Sendable () -> Date
    private let lock = NSRecursiveLock()

    public init(store: GwmSecureStore,
                client: GwmClient? = nil,
                preferences: Preferences = Preferences(),
                alertCenter: StatusAlertCenter = StatusAlertCenter(),
                now: @escaping @Sendable () -> Date = { Date() },
                emit: @escaping @Sendable (Event) -> Void) {
        self.store = store
        self.injectedClient = client
        self.preferences = preferences
        self.alertCenter = alertCenter
        self.now = now
        self.emitter = emit
        restoreFromDisk()
    }

    // MARK: - 冷启动恢复

    private func applyPendingStrategy() {
        client?.hvacStrategy = pendingHvacStrategy
    }

    private func restoreFromDisk() {
        if let injectedClient {
            client = injectedClient
            applyPendingStrategy()
            sessionState = injectedClient.isLoggedIn ? .active : .restoring
            return
        }
        if let saved = store.load() {
            client = saved
            applyPendingStrategy()
            sessionState = saved.isLoggedIn ? .active : .restoring
        } else {
            sessionState = .loggedOut
            sessionMessage = store.lastLoadError
        }
    }

    /// App 启动后调用一次，等价 Android 侧构造函数的后台任务。
    public func bootstrap() {
        guard let client else {
            emitter(.loginStateChanged(false))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if self.sessionState == .restoring {
                await self.restoreSessionQuietly()
            } else if self.sessionState == .active {
                await self.validateSavedSessionOnBoot(client)
            }
        }
    }

    private func validateSavedSessionOnBoot(_ client: GwmClient) async {
        do {
            let vehicles = try await client.getVehicles()
            guard !destroyed, self.client === client else { return }
            lastVehicles = vehicles
            persistQuietly(client)
            setSessionState(.active, nil)
            emitter(.loginStateChanged(true))
        } catch {
            if await client.reviveSessionQuietly() {
                persistQuietly(client)
                setSessionState(.active, nil)
                emitter(.loginStateChanged(true))
            } else if Self.isAuthFailure(error) {
                setSessionState(.expired, "登录已过期，需要重新验证")
                emitter(.loginStateChanged(false))
                emitter(.reauthRequired("登录已过期，请重新用短信验证码登录"))
            }
        }
    }

    // MARK: - 登录

    public func requestSmsCode(_ phone: String, completion: ResultCallback<Void>? = nil) {
        let candidate = client ?? GwmClient()
        Task { [weak self] in
            do {
                try await candidate.requestSmsCode(phone)
                guard let self else { return }
                self.adopt(candidate)
                completion?(.success(()))
            } catch {
                completion?(.failure(Self.friendly(error)))
            }
        }
    }

    public func loginSms(phone: String, code: String, completion: ResultCallback<[GwmVehicle]>? = nil) {
        let candidate = client ?? GwmClient()
        candidate.phone = phone.trimmingCharacters(in: .whitespaces)
        Task { [weak self] in
            do {
                let vehicles = try await candidate.loginSms(code)
                guard let self else { return }
                self.finishLogin(candidate, vehicles)
                completion?(.success(vehicles))
            } catch {
                completion?(.failure(Self.friendly(error)))
            }
        }
    }

    public func loginPassword(phone: String, password: String, completion: ResultCallback<[GwmVehicle]>? = nil) {
        let candidate = client ?? GwmClient()
        Task { [weak self] in
            do {
                let vehicles = try await candidate.loginPassword(phone, password)
                guard let self else { return }
                self.finishLogin(candidate, vehicles)
                completion?(.success(vehicles))
            } catch {
                completion?(.failure(Self.friendly(error)))
            }
        }
    }

    private func finishLogin(_ client: GwmClient, _ vehicles: [GwmVehicle]) {
        lock.lock()
        self.client = client
        lastVehicles = vehicles
        if vehicles.count == 1 { preferences.selectedVin = vehicles[0].vin }
        consecutiveFailures = 0
        lock.unlock()
        _ = store.save(client)
        setSessionState(.active, nil)
        emitter(.loginStateChanged(true))
        if preferences.pollEnabled { startPolling() }
    }

    public func logout() {
        stopPolling()
        lock.lock()
        client = nil
        lastStatus = nil
        lastError = nil
        lastUpdateAt = nil
        lastVehicles = nil
        preferences.selectedVin = nil
        lock.unlock()
        store.clear()
        setSessionState(.loggedOut, nil)
        emitter(.loginStateChanged(false))
    }

    // MARK: - 会话

    public var isLoggedIn: Bool { client?.isLoggedIn ?? false }
    public var hasAccount: Bool { client != nil }
    public var isSessionUsable: Bool { sessionState == .active && isLoggedIn }
    public var phone: String { client?.phone ?? "" }

    public func platformOf(_ vin: String? = nil) -> String {
        guard let client else { return "" }
        return client.cachedPlatform(vin ?? preferences.selectedVin)
    }

    public func selectedVin() -> String? { preferences.selectedVin }

    public func selectedVehicle() -> GwmVehicle? {
        guard let vin = preferences.selectedVin, let lastVehicles else { return nil }
        return lastVehicles.first { $0.vin.caseInsensitiveCompare(vin) == .orderedSame }
    }

    public func setSelectedVin(_ vin: String?) {
        preferences.selectedVin = vin
    }

    public func setPollEnabled(_ enabled: Bool) {
        preferences.pollEnabled = enabled
        if enabled { startPolling() } else { stopPolling() }
    }

    public var isPollEnabled: Bool { preferences.pollEnabled }
    public var pollIntervalSeconds: Int { preferences.pollIntervalSeconds }

    /// gtsp 通道空调策略，透传给客户端。
    public func setHvacStrategy(_ strategy: GwmClient.HvacStrategy) {
        client?.hvacStrategy = strategy
        pendingHvacStrategy = strategy
    }

    private var pendingHvacStrategy: GwmClient.HvacStrategy = .dedicatedCodes

    public func setPollIntervalSeconds(_ seconds: Int) {
        preferences.pollIntervalSeconds = max(Self.minInterval, min(3600, seconds))
    }

    public func setRemoteEnabled(_ enabled: Bool) {
        preferences.remoteEnabled = enabled
    }

    public var isRemoteEnabled: Bool { preferences.remoteEnabled }

    public func currentStatus() -> VehicleStatus? { lastStatus }

    private func rememberRawStatus(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        lastRawStatus = json
    }

    /// 乐观更新当前车况（原实现里小组件下发成功后会先改本地状态再刷新）。
    /// 也用于测试中预置初始车况。
    public func setCurrentStatus(_ status: VehicleStatus?) {
        lock.lock(); defer { lock.unlock() }
        lastStatus = status
    }

    public func refreshNow() {
        Task { [weak self] in await self?.refresh(notifyErrors: true) }
    }

    public func restoreSessionQuietly() async {
        guard let client else {
            setSessionState(.loggedOut, nil)
            emitter(.loginStateChanged(false))
            return
        }
        if client.isLoggedIn {
            setSessionState(.active, nil)
            emitter(.loginStateChanged(true))
            if preferences.pollEnabled { startPolling() }
            return
        }
        guard client.hasRefreshableSession else {
            setSessionState(.expired, "登录凭据不完整，需要重新验证")
            emitter(.loginStateChanged(false))
            emitter(.reauthRequired("登录凭据不完整，请重新用短信验证码登录"))
            return
        }
        if await client.reviveSessionQuietly() {
            persistQuietly(client)
            setSessionState(.active, nil)
            emitter(.loginStateChanged(true))
            if preferences.pollEnabled { startPolling() }
        } else {
            setSessionState(.expired, "登录已过期，需要重新验证一次")
            emitter(.loginStateChanged(false))
            emitter(.reauthRequired("登录已过期，请重新用短信验证码登录"))
        }
    }

    public func verifySession(completion: @escaping @Sendable (Bool, String?) -> Void) {
        guard let client, client.isLoggedIn else {
            completion(false, "未登录")
            return
        }
        Task { [weak self] in
            do {
                let vehicles = try await client.getVehicles()
                self?.rememberVehicles(vehicles)
                self?.persistQuietly(client)
                completion(true, nil)
            } catch {
                do {
                    try await client.recoverSession()
                    self?.persistQuietly(client)
                    completion(true, nil)
                } catch {
                    completion(false, Self.friendly(error).friendlyMessage)
                }
            }
        }
    }

    // MARK: - 轮询

    public func startPolling() {
        guard !destroyed, preferences.pollEnabled, isLoggedIn else { return }
        if pollTask != nil { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.pollLoop()
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            guard !destroyed, preferences.pollEnabled, isLoggedIn else { break }
            await pollOnce()
            let delay = nextDelay()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// 失败退避：interval * 2^min(failures,6)，上限 10 分钟。
    func nextDelay() -> TimeInterval {
        guard consecutiveFailures > 0 else { return TimeInterval(preferences.pollIntervalSeconds) }
        let factor = Double(1 << min(consecutiveFailures, 6))
        return min(Self.maxBackoff, TimeInterval(preferences.pollIntervalSeconds) * factor)
    }

    public func pollOnce() async {
        guard !polling else { return }
        polling = true
        await refresh(notifyErrors: false)
        polling = false
    }

    // MARK: - 刷新

    private func refresh(notifyErrors: Bool) async {
        guard let client else {
            if notifyErrors { emitter(.statusUpdated(nil, "未登录")) }
            return
        }
        guard client.isLoggedIn else {
            if notifyErrors { emitter(.statusUpdated(nil, "未登录")) }
            return
        }
        var vin = preferences.selectedVin ?? ""
        if vin.isEmpty {
            do {
                let vehicles = try await client.getVehicles()
                rememberVehicles(vehicles)
                guard !vehicles.isEmpty else {
                    emitter(.statusUpdated(nil, "账号下没有车辆"))
                    return
                }
                vin = vehicles[0].vin
                preferences.selectedVin = vin
            } catch {
                emitter(.statusUpdated(nil, Self.friendly(error).friendlyMessage))
                return
            }
        }

        emitter(.refreshing(true))
        do {
            // 先取原始 JSON 留档，再解析，便于按云端真实字段核对定位等字段名
            let raw = try await client.getStatus(vin)
            rememberRawStatus(GwmCrypto.encodeDotnetJSON(raw))
            let status = VehicleStatus.parse(raw)
            applySuccess(status, client)
            emitter(.refreshing(false))
        } catch {
            emitter(.refreshing(false))
            if Self.isAuthFailure(error) {
                do {
                    try await client.recoverSession()
                    let raw = try await client.getStatus(vin)
                    rememberRawStatus(GwmCrypto.encodeDotnetJSON(raw))
                    let status = VehicleStatus.parse(raw)
                    persistQuietly(client)
                    applySuccess(status, client)
                } catch {
                    await handleFailure(error, client: client)
                }
            } else {
                await handleFailure(error, client: client)
            }
        }
    }

    private func applySuccess(_ status: VehicleStatus, _ client: GwmClient) {
        lock.lock()
        lastStatus = status
        lastError = nil
        lastUpdateAt = now()
        consecutiveFailures = 0
        lock.unlock()
        persistQuietly(client)
        markSessionActiveIfNeeded()
        emitter(.statusUpdated(status, nil))
        for alert in alertCenter.onStatusUpdated(status) {
            emitter(.alert(alert))
        }
    }

    private func handleFailure(_ error: Error, client: GwmClient) async {
        consecutiveFailures += 1
        let message = Self.friendly(error).friendlyMessage
        lastError = message
        emitter(.statusUpdated(lastStatus, message))
        guard consecutiveFailures >= 3 else { return }
        if await client.reviveSessionQuietly() {
            persistQuietly(client)
            consecutiveFailures = 0
            setSessionState(.active, nil)
            emitter(.refreshing(false))
            return
        }
        setSessionState(.expired, "登录已过期，需要重新验证")
        emitter(.reauthRequired(message))
        emitter(.loginStateChanged(false))
        stopPolling()
    }

    private func markSessionActiveIfNeeded() {
        guard isLoggedIn, sessionState != .active else { return }
        setSessionState(.active, nil)
        emitter(.loginStateChanged(true))
    }

    private func setSessionState(_ state: SessionState, _ message: String?) {
        sessionState = state
        sessionMessage = message
    }

    /// 同步设置当前客户端，避免在 async 上下文里直接操作锁。
    private func adopt(_ client: GwmClient) {
        lock.lock(); defer { lock.unlock() }
        self.client = client
    }

    private func rememberVehicles(_ vehicles: [GwmVehicle]) {
        lock.lock(); defer { lock.unlock() }
        lastVehicles = vehicles
    }

    private func persistQuietly(_ client: GwmClient) {
        guard self.client === client else { return }
        _ = store.save(client)
    }

    // MARK: - 指令

    public func sendCommand(_ controlType: String, body: JSONValue?,
                            completion: @escaping @Sendable (Result<String, GwmError>) -> Void) {
        guard let client else {
            completion(.failure(GwmError.auth("请先登录")))
            return
        }
        let vin = preferences.selectedVin ?? ""
        guard !vin.isEmpty else {
            completion(.failure(GwmError.auth("请先选择车辆")))
            return
        }
        Task { [weak self] in
            var active = client
            if !client.isLoggedIn {
                if await client.reviveSessionQuietly() {
                    active = client
                    self?.persistQuietly(client)
                } else {
                    completion(.failure(GwmError.auth("登录已过期，请重新打开 App")))
                    return
                }
            }
            do {
                let sequence = try await active.sendCommand(vin, controlType, body)
                self?.persistQuietly(active)
                completion(.success(sequence))
                // 与原实现一致：下发成功后延迟 6 秒刷新一次车况
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await self?.refresh(notifyErrors: false)
            } catch {
                completion(.failure(Self.friendly(error)))
            }
        }
    }

    public func queryCommandResult(vin: String?, sequence: String,
                                   completion: @escaping @Sendable (Result<JSONValue?, GwmError>) -> Void) {
        guard let client, client.isLoggedIn else {
            completion(.failure(GwmError.auth("请先登录")))
            return
        }
        let target = vin ?? preferences.selectedVin ?? ""
        guard !target.isEmpty else {
            completion(.failure(GwmError.auth("请先选择车辆")))
            return
        }
        Task { [weak self] in
            do {
                let result = try await client.getCommandResult(target, sequence)
                self?.persistQuietly(client)
                completion(.success(result))
            } catch {
                completion(.failure(Self.friendly(error)))
            }
        }
    }

    public func fetchVehicles(completion: @escaping @Sendable (Result<[GwmVehicle], GwmError>) -> Void) {
        guard let client else {
            completion(.failure(GwmError.auth("未登录")))
            return
        }
        Task { [weak self] in
            do {
                let vehicles = try await client.getVehicles()
                self?.rememberVehicles(vehicles)
                self?.persistQuietly(client)
                completion(.success(vehicles))
            } catch {
                completion(.failure(Self.friendly(error)))
            }
        }
    }

    public func shutdown() {
        destroyed = true
        stopPolling()
    }

    // MARK: - 错误文案

    static func friendly(_ error: Error) -> GwmError {
        if let error = error as? GwmError { return error }
        return GwmError.connection(error.localizedDescription)
    }

    static func isAuthFailure(_ error: Error) -> Bool {
        guard case let .auth(message) = friendly(error) else { return false }
        return message.contains("会话") || message.contains("-101") || message.contains("认证")
            || message.contains("token") || message.contains("login") || message.contains("401")
    }
}
