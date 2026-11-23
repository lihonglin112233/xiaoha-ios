import Foundation

/// 车辆状态模型，字段与解析规则对齐原 APK 的 VehicleStatus。
public struct VehicleStatus: Equatable, Sendable {
    public var acAutoMode: Bool?
    public var acTempSet: Double?
    public var acquisitionTime: String?
    public var airConditioner: Bool?
    public var antitheft: Bool?
    public var avgEnergyConsumption: Double?
    public var avgFuelConsumption: Double?
    public var batteryPercent: Double?
    public var batteryVoltage: Double?
    public var cabinClean: Bool?
    public var cabinTemp: Double?
    public var doorFrontLeft: Bool?
    public var doorFrontRight: Bool?
    public var doorRearLeft: Bool?
    public var doorRearRight: Bool?
    public var doorTrunk: Bool?
    public var doorsLocked: Bool?
    public var engineState: String?
    public var evRange: Double?
    public var frontDefroster: Bool?
    public var fuelGauge: String?
    public var fuelRange: Double?
    public var fuelVolume: Double?
    public var gear: String?
    public var gpsSwitchOn: String?
    public var highBeam: Bool?
    public var hood: Bool?
    public var lowBeam: Bool?
    public var mileage: Double?
    public var oilAlarm: Bool?
    public var powerState: String?
    public var rearDefroster: Bool?
    public var seatHeatDriver: Bool?
    public var seatHeatPassenger: Bool?
    public var seatHeatRearLeft: Bool?
    public var seatHeatRearRight: Bool?
    public var seatVentDriver: Bool?
    public var seatVentPassenger: Bool?
    public var steerWheelHeat: Bool?
    public var sunroof: Bool?
    public var tboxStatus: String?
    public var tireAlarmFl: Bool?
    public var tireAlarmFr: Bool?
    public var tireAlarmRl: Bool?
    public var tireAlarmRr: Bool?
    public var tirePressureFl: Double?
    public var tirePressureFr: Double?
    public var tirePressureRl: Double?
    public var tirePressureRr: Double?
    public var tireTempFl: Double?
    public var tireTempFr: Double?
    public var tireTempRl: Double?
    public var tireTempRr: Double?
    /// 车辆定位。原 APK 不解析经纬度，这里按常见字段名容错提取；
    /// 服务端未返回时为 nil，界面需如实说明"未上报"。
    public var latitude: Double?
    public var longitude: Double?
    public var positionTime: String?
    public var windowFrontLeft: Bool?
    public var windowFrontRight: Bool?
    public var windowRearLeft: Bool?
    public var windowRearRight: Bool?
    public var windshieldHeat: Bool?

    public init() {}

    // MARK: - 解析

    /// 对应 GwmCrypto.normalizeKeys：递归把 key 转小写，保持插入顺序。
    static func normalizeKeys(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(pairs):
            return .object(pairs.map { ($0.0.lowercased(), normalizeKeys($0.1)) })
        case let .array(items):
            return .array(items.map(normalizeKeys))
        default:
            return value
        }
    }

    static func first(_ values: JSONValue?...) -> JSONValue? {
        for value in values where value != nil {
            if case .some(.null) = value { continue }
            return value
        }
        return nil
    }

    public static func parse(_ map: JSONValue?) -> VehicleStatus {
        var status = VehicleStatus()
        guard let map, let pairs = map.asObject, !pairs.isEmpty else { return status }
        let root = normalizeKeys(map)

        // acquisitiontime 在根节点与 vehiclestatusinfo 下都可能出现
        let info: JSONValue = root.value("vehiclestatusinfo")?.asObject != nil
            ? root.value("vehiclestatusinfo")!
            : .object([])

        status.acquisitionTime = asString(first(root.value("acquisitiontime"), info.value("acquisitiontime")))
        status.gpsSwitchOn = asString(first(info.value("gpsswitchon"), root.value("gpsswitchon")))
        // 定位：参考 chaosl1996/gwm_cn_ha 的实测路径，云端把经纬度放在
        // 车况报文顶层（data.latitude / data.longitude）；其余命名再走递归语义扫描。
        let topLat = Self.parseCoordinate(first(root.value("latitude"), root.value("lat")))
        let topLon = Self.parseCoordinate(first(root.value("longitude"), root.value("lon"), root.value("lng")))
        let location: (lat: Double?, lon: Double?, time: String?)
        if let topLat, let topLon {
            location = (topLat, topLon,
                        asString(first(root.value("acquisitiontime"), root.value("acquisitionTime"))))
        } else {
            location = Self.extractLocation(root)
        }
        status.latitude = location.lat
        status.longitude = location.lon
        status.positionTime = location.time
        status.tboxStatus = asString(first(root.value("tboxstatus"), info.value("tboxstate"), info.value("tboxstatus")))
        status.fuelGauge = asString(first(info.value("oilqty"), root.value("oilqty")))
        status.fuelVolume = parseValue(info.value("remainoil"))
        status.fuelRange = parseValue(info.value("premileage"))
        status.batteryPercent = parseValue(info.value("remainelectricpercent"))
        status.mileage = parseValue(info.value("mileage"))
        if let charge = info.value("charge") {
            status.evRange = parseValue(charge.value("evcontnsdistance"))
        }
        status.avgFuelConsumption = parseValue(info.value("avgfuelconse"))
        status.avgEnergyConsumption = parseValue(info.value("avrgegycns"))
        status.batteryVoltage = parseValue(info.value("bmspackvolt"))
        status.cabinTemp = parseValue(first(info.value("cbntemp"), info.value("incartemperature")))

        var acTemp = parseValue(first(
            info.value("actemp"), info.value("settemp"), info.value("hvactemp"),
            info.value("drvtemp"), info.value("drvtemptarget")
        ))
        if let value = acTemp, value > 60.0 { acTemp = value / 10.0 }
        if let value = acTemp, value < 10.0 || value > 40.0 { acTemp = nil }
        status.acTempSet = acTemp

        status.engineState = asString(first(info.value("enginests"), root.value("enginests")))
        status.powerState = asString(info.value("power"))
        status.gear = asString(first(info.value("hcugearsts"), info.value("gearsts")))
        status.doorsLocked = toBoolInverted(info.value("escllocksts"))
        if status.doorsLocked == nil, let door = info.value("door"), door.asObject != nil {
            status.doorsLocked = toBoolInverted(door.value("maindrvedoorlocksts"))
        }
        if let door = info.value("door"), door.asObject != nil {
            status.doorFrontLeft = toBool(door.value("maindrvedoorsts"))
            status.doorFrontRight = toBool(door.value("vicedoorsts"))
            status.doorRearLeft = toBool(door.value("lbdoorsts"))
            status.doorRearRight = toBool(door.value("rbdoorsts"))
            status.doorTrunk = toBool(first(door.value("backdoorsts"), door.value("tailgateopenupsts")))
        }
        status.hood = toBool(info.value("enginedoorsts"))
        if let windows = info.value("windows"), windows.asObject != nil {
            status.windowFrontLeft = windowPosToBool(windows.value("lfwinposnsts"), "1")
            status.windowFrontRight = windowPosToBool(windows.value("rfwinposnsts"), "1")
            status.windowRearLeft = windowPosToBool(windows.value("lbwinposnsts"), "1")
            status.windowRearRight = windowPosToBool(windows.value("rbwinposnsts"), "1")
            status.sunroof = windowPosToBool(windows.value("skylightsts"), "3")
            status.windshieldHeat = toBool(windows.value("fwinheatsts"))
        }
        status.airConditioner = toBool(info.value("airconditionsts"))
        status.acAutoMode = toBool(first(info.value("airconditionautomodenasts"), info.value("acautomodests")))
        status.frontDefroster = toBool(info.value("frontfrost"))
        status.rearDefroster = toBool(info.value("backfrost"))
        if let lighting = info.value("lighting"), lighting.asObject != nil {
            status.lowBeam = toBool(lighting.value("nearbeamsts"))
            status.highBeam = toBool(lighting.value("farbeamsts"))
        }
        status.steerWheelHeat = toBool(first(info.value("steerwheelheat"), info.value("steerwheelheatdsts")))
        status.cabinClean = toBool(info.value("cabinclean"))
        if let seat = info.value("seat"), seat.asObject != nil {
            status.seatHeatDriver = toBool(seat.value("maindriverseatheatsts"))
            status.seatVentDriver = toBool(seat.value("maindriverseatventsts"))
            status.seatHeatPassenger = toBool(seat.value("viceseatheatsts"))
            status.seatVentPassenger = toBool(seat.value("viceseatventsts"))
            status.seatHeatRearLeft = toBool(seat.value("lbseatheatsts"))
            status.seatHeatRearRight = toBool(seat.value("rbseatheatsts"))
        }
        if let tire = info.value("tirepress"), tire.asObject != nil {
            status.tirePressureFl = parseValue(tire.value("lftirepressval"))
            status.tirePressureFr = parseValue(tire.value("rftirepressval"))
            status.tirePressureRl = parseValue(tire.value("lbtirepressval"))
            status.tirePressureRr = parseValue(tire.value("rbtirepressval"))
            status.tireAlarmFl = toBool(first(tire.value("lftirepressindcrsts"), tire.value("lftirepresssts")))
            status.tireAlarmFr = toBool(first(tire.value("rftirepressindcrsts"), tire.value("rftirepresssts")))
            status.tireAlarmRl = toBool(first(tire.value("lbtirepressindcrsts"), tire.value("lbtirepresssts")))
            status.tireAlarmRr = toBool(first(tire.value("rbtirepressindcrsts"), tire.value("rbtirepresssts")))
        }
        if let temp = info.value("tiretemp"), temp.asObject != nil {
            status.tireTempFl = parseValue(temp.value("lftiretempval"))
            status.tireTempFr = parseValue(temp.value("rftiretempval"))
            status.tireTempRl = parseValue(temp.value("lbtiretempval"))
            status.tireTempRr = parseValue(temp.value("rbtiretempval"))
        }
        status.antitheft = toBool(info.value("vehicleantitheftstatus"))
        status.oilAlarm = toBool(info.value("oilalarmsts"))
        return status
    }

    static func asString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(s):
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case let .number(n):
            if n == JavaMath.rint(n) { return String(JavaMath.truncate(n)) }
            return JavaMath.doubleToString(n)
        case let .bool(b):
            return b ? "true" : "false"
        case .null:
            return nil
        default:
            return nil
        }
    }

    public static func parseValue(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case let .number(n):
            return n
        case let .string(s):
            var trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "--" || trimmed.lowercased() == "null" { return nil }
            if let comma = trimmed.firstIndex(of: ",") {
                trimmed = String(trimmed[trimmed.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
            }
            return Double(trimmed)
        default:
            return nil
        }
    }

    /// 列出报文里所有 key 的路径（用于诊断"云端到底有没有坐标字段"）。
    public static func keyPaths(_ root: JSONValue, limit: Int = 400) -> [String] {
        var out: [String] = []
        func walk(_ node: JSONValue, _ prefix: String) {
            guard out.count < limit else { return }
            if let pairs = node.asObject {
                for (key, value) in pairs {
                    let path = prefix.isEmpty ? key : prefix + "." + key
                    out.append(path)
                    walk(value, path)
                }
            } else if let items = node.asArray, let firstItem = items.first {
                walk(firstItem, prefix + "[]")
            }
        }
        walk(root, "")
        return out
    }

    // MARK: - 定位提取

    static func normalizeKey(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// 含 lat/lon 字样但语义无关的键，避免误判。
    static let excludedLabelKeys: Set<String> = [
        "platform", "translate", "latest", "relate", "related", "flat", "layout",
        "plate", "inflate", "lateral", "collate", "template", "violate",
    ]

    static func isLatitudeKey(_ key: String) -> Bool {
        let exact: Set<String> = [
            "lat", "latitude", "gpslat", "gpslatitude", "poslat", "positionlat",
            "loclat", "locationlat", "vehiclelat", "latval", "latvalue", "latitudevalue",
        ]
        if exact.contains(key) { return true }
        // 允许 "vehicleLat / gpsLat / positionLat" 这类前缀变体。
        // 不用长度限制（会误伤 vehiclelatitude），改用排除表挡住无关词。
        if excludedLabelKeys.contains(key) { return false }
        return key.hasSuffix("latitude") || key.hasSuffix("lat")
    }

    static func isLongitudeKey(_ key: String) -> Bool {
        let exact: Set<String> = [
            "lon", "lng", "long", "longitude", "gpslon", "gpslng", "gpslongitude",
            "poslon", "poslng", "positionlon", "loclon", "locationlon",
            "vehiclelon", "lonval", "lonvalue", "lngval", "longitudevalue",
        ]
        if exact.contains(key) { return true }
        if excludedLabelKeys.contains(key) { return false }
        return key.hasSuffix("longitude") || key.hasSuffix("lon")
            || key.hasSuffix("lng") || key.hasSuffix("long")
    }

    static func isPositionTimeKey(_ key: String) -> Bool {
        let exact: Set<String> = [
            "positiontime", "postime", "gpstime", "locationtime", "loctime",
            "reporttime", "updatetime", "acquisitiontime", "timestamp", "time",
        ]
        return exact.contains(key)
    }

    /// 递归扫描报文，找出最可信的一组经纬度。
    /// 同一对象内同时含经纬度的优先级最高；数值会做范围校验。
    static func extractLocation(_ root: JSONValue) -> (lat: Double?, lon: Double?, time: String?) {
        var bestLat: Double?
        var bestLon: Double?
        var bestTime: String?
        var bestScore = -1

        func validLat(_ value: JSONValue?) -> Double? {
            guard let raw = parseCoordinate(value), abs(raw) <= 90 else { return nil }
            return raw
        }
        func validLon(_ value: JSONValue?) -> Double? {
            guard let raw = parseCoordinate(value), abs(raw) <= 180 else { return nil }
            return raw
        }

        func visit(_ node: JSONValue) {
            if let pairs = node.asObject {
                var lat: Double?
                var lon: Double?
                var time: String?
                for (key, value) in pairs {
                    let k = normalizeKey(key)
                    if lat == nil, isLatitudeKey(k) { lat = validLat(value) }
                    if lon == nil, isLongitudeKey(k) { lon = validLon(value) }
                    if time == nil, isPositionTimeKey(k) { time = asString(value) }
                }
                if lat != nil || lon != nil {
                    var score = 0
                    if lat != nil { score += 1 }
                    if lon != nil { score += 1 }
                    if lat != nil && lon != nil { score += 3 }  // 成对最可信
                    if time != nil { score += 1 }
                    if score > bestScore {
                        bestScore = score
                        bestLat = lat
                        bestLon = lon
                        bestTime = time
                    }
                }
            }
            if let pairs = node.asObject {
                for (_, value) in pairs { visit(value) }
            } else if let items = node.asArray {
                for item in items { visit(item) }
            }
        }

        visit(root)
        // 坐标必须成对才有意义
        if bestLat == nil || bestLon == nil {
            return (nil, nil, bestTime)
        }
        return (bestLat, bestLon, bestTime)
    }

    /// 解析经纬度：非法值（越界、0,0、占位符）一律视为未上报。
    static func parseCoordinate(_ value: JSONValue?) -> Double? {
        guard let raw = parseValue(value) else { return nil }
        // 0,0 是无效坐标（大西洋几内亚湾），视为未上报
        if raw == 0 { return nil }
        return raw
    }

    /// 坐标是否可用（成对且在中国大陆/常规范围内）。
    public var hasCoordinate: Bool {
        guard let latitude, let longitude else { return false }
        return abs(latitude) <= 90 && abs(longitude) <= 180
    }

    static func statusText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let text: String
        switch value {
        case let .bool(b):
            text = b ? "1" : "0"
        case let .number(n):
            text = n == JavaMath.rint(n) ? String(JavaMath.truncate(n)) : JavaMath.doubleToString(n)
        case let .string(s):
            text = s.trimmingCharacters(in: .whitespaces)
        default:
            text = ""
        }
        if text.isEmpty || text == "--" || text.lowercased() == "null" { return nil }
        return text
    }

    public static func toBool(_ value: JSONValue?, truthy: String = "1", falsy: String = "0") -> Bool? {
        guard let text = statusText(value) else { return nil }
        if text == truthy { return true }
        if text == falsy { return false }
        return nil
    }

    static func toBoolInverted(_ value: JSONValue?) -> Bool? {
        guard let text = statusText(value) else { return nil }
        if text == "0" { return true }
        if text == "1" { return false }
        return nil
    }

    static func windowPosToBool(_ value: JSONValue?, _ closedCode: String) -> Bool? {
        guard let text = statusText(value) else { return nil }
        return text == closedCode ? false : true
    }

    // MARK: - 文本与判定

    public func engineText() -> String {
        switch engineState {
        case "0": return "未启动"
        case "1": return "启动中"
        case "2": return "已启动"
        default: return "未知"
        }
    }

    public func hasOpenDoor() -> Bool {
        doorFrontLeft == true || doorFrontRight == true || doorRearLeft == true
            || doorRearRight == true || doorTrunk == true || hood == true
    }

    public func hasOpenWindow() -> Bool {
        windowFrontLeft == true || windowFrontRight == true || windowRearLeft == true
            || windowRearRight == true || sunroof == true
    }

    public func hasTireAlarm() -> Bool {
        tireAlarmFl == true || tireAlarmFr == true || tireAlarmRl == true || tireAlarmRr == true
    }

    public func isEmpty() -> Bool {
        engineState == nil && mileage == nil && fuelRange == nil && doorsLocked == nil && tirePressureFl == nil
    }

    public func isEngineRunning() -> Bool {
        engineState == "1" || engineState == "2"
    }

    public func isParked() -> Bool {
        if !isEngineRunning() { return true }
        guard let gear else { return false }
        let upper = gear.trimmingCharacters(in: .whitespaces).uppercased()
        return upper == "15" || upper == "0" || upper == "1"
            || upper.hasPrefix("P") || upper.hasPrefix("N") || upper.contains("驻车")
    }

    public var isDoorsLocked: Bool { doorsLocked == true }

    public func securitySummary() -> String {
        var parts: [String] = []
        if let doorsLocked {
            parts.append(doorsLocked ? "已锁车" : "未锁车")
        } else {
            parts.append("门锁未知")
        }
        if hasOpenDoor() { parts.append("有车门未关") }
        if hasOpenWindow() { parts.append("有车窗未关") }
        if hasTireAlarm() { parts.append("胎压异常") }
        return parts.joined(separator: " · ")
    }

    public func summary() -> String {
        func num(_ value: Double?) -> String { value.map { JavaMath.doubleToString($0) } ?? "-" }
        let lockText = doorsLocked.map { $0 ? "已锁" : "未锁" } ?? "-"
        return "引擎=\(engineText()) 续航=\(num(fuelRange))km 油量=\(num(fuelVolume))L "
            + "里程=\(num(mileage))km 车门锁=\(lockText) 车门开=\(hasOpenDoor()) 窗开=\(hasOpenWindow())"
    }
}
