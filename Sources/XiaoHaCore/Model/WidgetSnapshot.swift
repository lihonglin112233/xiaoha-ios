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

    /// App Group 在自签 / TrollStore 环境可能不可用（没有真实 provisioning profile），
    /// 此时退回到标准 UserDefaults：同一进程内仍可用，跨进程共享会失效。
    private static var container: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    public static func isSharedContainerAvailable() -> Bool {
        UserDefaults(suiteName: suiteName) != nil
    }

    public static func load() -> WidgetSnapshot {
        WidgetSnapshot.decoded(container.data(forKey: key)) ?? WidgetSnapshot()
    }

    public static func save(_ snapshot: WidgetSnapshot) {
        guard let data = snapshot.encoded() else { return }
        container.set(data, forKey: key)
    }
}
