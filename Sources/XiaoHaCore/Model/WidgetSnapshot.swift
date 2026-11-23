import Foundation

/// 主 App 与桌面小组件共享的状态快照（经 App Group 传递）。
public struct WidgetSnapshot: Codable, Sendable {
    public var vehicleName: String
    public var subtitle: String
    public var engineText: String
    public var engineRunning: Bool
    public var locked: Bool?
    public var battery: Double?
    public var range: Double?
    public var acOn: Bool?
    public var updatedAt: Date?

    public init(vehicleName: String = "我的车辆", subtitle: String = "", engineText: String = "--",
                engineRunning: Bool = false, locked: Bool? = nil, battery: Double? = nil,
                range: Double? = nil, acOn: Bool? = nil, updatedAt: Date? = nil) {
        self.vehicleName = vehicleName
        self.subtitle = subtitle
        self.engineText = engineText
        self.engineRunning = engineRunning
        self.locked = locked
        self.battery = battery
        self.range = range
        self.acOn = acOn
        self.updatedAt = updatedAt
    }

    public init(status: VehicleStatus?, vehicle: GwmVehicle?, updatedAt: Date?) {
        self.init()
        vehicleName = vehicle?.displayName() ?? "我的车辆"
        subtitle = vehicle?.subtitleWithPlatform(nil) ?? ""
        self.updatedAt = updatedAt
        guard let status else { return }
        engineText = status.engineText()
        engineRunning = status.isEngineRunning()
        locked = status.doorsLocked
        battery = status.batteryPercent
        range = status.fuelRange
        acOn = status.airConditioner
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decoded(_ data: Data?) -> WidgetSnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

/// App Group 容器读写。
public enum WidgetStore {
    public static let suiteName = "group.com.xiaoha.car"
    public static let key = "widget_snapshot"

    /// 注意：UserDefaults(suiteName:) 在缺少 App Group 权限时仍会返回非 nil，
    /// 但那份数据落在"本 App 私有"域里，小组件进程读不到。
    /// 所以这里同时写共享域与标准域，读取时优先共享域，尽量提高命中率。
    private static var shared: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// App Group 是否真的可用（用能否读到共享域写入来验证）。
    public static func isSharedContainerAvailable() -> Bool {
        guard let shared else { return false }
        let probe = "widget_probe"
        let token = UUID().uuidString
        shared.set(token, forKey: probe)
        let ok = shared.string(forKey: probe) == token
        shared.removeObject(forKey: probe)
        return ok
    }

    public static func save(_ snapshot: WidgetSnapshot) {
        guard let data = snapshot.encoded() else { return }
        // 共享域（小组件能读到）
        shared?.set(data, forKey: key)
        // 标准域兜底（主 App 自己下次启动仍能读到）
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func load() -> WidgetSnapshot {
        if let data = shared?.data(forKey: key), let snapshot = WidgetSnapshot.decoded(data) {
            return snapshot
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let snapshot = WidgetSnapshot.decoded(data) {
            return snapshot
        }
        return WidgetSnapshot()
    }

    /// 供界面显示"小组件为何没数据"的诊断信息。
    public static func diagnostics() -> String {
        let sharedAvailable = isSharedContainerAvailable()
        let hasData = shared?.data(forKey: key) != nil
        if !sharedAvailable {
            return "App Group 不可用：小组件无法读取数据（自签/TrollStore 可能缺少 entitlement）"
        }
        return hasData ? "共享数据正常" : "App Group 可用，但还没有写入过车况"
    }
}
