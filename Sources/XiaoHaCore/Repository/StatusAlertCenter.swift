import Foundation

/// 状态变化提醒，对齐原 APK 的 StatusAlertCenter（去掉 Android 通知，改由上层展示）。
public final class StatusAlertCenter: @unchecked Sendable {
    public struct Alert: Equatable, Sendable {
        public let item: String
        public let text: String
        public let good: Bool

        public init(item: String, text: String, good: Bool) {
            self.item = item
            self.text = text
            self.good = good
        }
    }

    struct Snapshot: Equatable {
        var acOn: Bool?
        var batteryPercent: Double?
        var doorsLocked: Bool?
        var engineRunning: Bool?
        var fuelRange: Double?
        var trunkOpen: Bool?
        var windowOpen: Bool?
    }

    private var last: Snapshot?
    private(set) public var unreadCount = 0

    public init() {}

    static func snapshotOf(_ status: VehicleStatus) -> Snapshot {
        Snapshot(
            acOn: status.airConditioner,
            batteryPercent: status.batteryPercent,
            doorsLocked: status.doorsLocked,
            engineRunning: status.isEngineRunning(),
            fuelRange: status.fuelRange,
            trunkOpen: status.doorTrunk,
            windowOpen: status.hasOpenWindow()
        )
    }

    static func changed(_ previous: Bool?, _ current: Bool?) -> Bool {
        guard let previous, let current else { return false }
        return previous != current
    }

    /// 返回 nil 表示这是首次快照（只记录，不产生提醒）。
    public func diff(_ status: VehicleStatus?) -> [Alert]? {
        guard let status else { return [] }
        let current = Self.snapshotOf(status)
        let previous = last
        last = current
        guard let previous else { return nil }

        var alerts: [Alert] = []
        if Self.changed(previous.doorsLocked, current.doorsLocked) {
            let locked = current.doorsLocked == true
            alerts.append(Alert(item: "门锁", text: locked ? "车辆已闭锁" : "车辆已解锁", good: locked))
        }
        if Self.changed(previous.windowOpen, current.windowOpen) {
            let open = current.windowOpen == true
            alerts.append(Alert(item: "车窗", text: open ? "检测到车窗被打开" : "车窗已全部关闭", good: !open))
        }
        if Self.changed(previous.trunkOpen, current.trunkOpen) {
            let open = current.trunkOpen == true
            alerts.append(Alert(item: "后备箱", text: open ? "后备箱已打开" : "后备箱已关闭", good: !open))
        }
        if Self.changed(previous.engineRunning, current.engineRunning) {
            let running = current.engineRunning == true
            alerts.append(Alert(item: "发动机", text: running ? "发动机已启动" : "发动机已熄火", good: running))
        }
        if Self.changed(previous.acOn, current.acOn) {
            let on = current.acOn == true
            alerts.append(Alert(item: "空调", text: on ? "空调已开启" : "空调已关闭", good: on))
        }
        if let battery = current.batteryPercent, let oldBattery = previous.batteryPercent {
            let newTier = Int((battery / 10.0).rounded(.down))
            let oldTier = Int((oldBattery / 10.0).rounded(.down))
            if newTier < oldTier, battery <= 30.0 {
                alerts.append(Alert(item: "电量",
                                    text: "电量已低于 \((newTier + 1) * 10)%（当前 \(Int(battery.rounded()))%）",
                                    good: false))
            }
        }
        if let range = current.fuelRange, let oldRange = previous.fuelRange {
            let newTier = Int((range / 50.0).rounded(.down))
            let oldTier = Int((oldRange / 50.0).rounded(.down))
            if range < oldRange, newTier < oldTier, range <= 100.0 {
                alerts.append(Alert(item: "续航",
                                    text: "续航不足 \((newTier + 1) * 50) km（当前 \(Int(range.rounded())) km）",
                                    good: false))
            }
        }
        return alerts
    }

    public func onStatusUpdated(_ status: VehicleStatus?) -> [Alert] {
        guard let alerts = diff(status) else { return [] }
        unreadCount += alerts.count
        return alerts
    }

    public func clearUnread() {
        unreadCount = 0
    }
}
