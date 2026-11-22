import XCTest
@testable import XiaoHaCore

/// 逐字段比对 Java 原实现的解析结果（status_golden.txt 由反编译后的 VehicleStatus 直接运行产出）。
final class StatusGoldenTests: XCTestCase {
    static var golden: [String: [String: String]] = [:]

    override class func setUp() {
        super.setUp()
        guard let url = Bundle.module.url(forResource: "status_golden", withExtension: "txt", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "status_golden", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("缺少 status_golden.txt")
            return
        }
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                current = String(trimmed.dropFirst(3))
                golden[current!] = [:]
            } else if let current, !trimmed.isEmpty, let eq = trimmed.firstIndex(of: "=") {
                golden[current]![String(trimmed[trimmed.startIndex..<eq])] = String(trimmed[trimmed.index(after: eq)...])
            }
        }
    }

    /// 把 Swift 的 VehicleStatus 转成与 Java 反射输出一致的字典。
    static func fields(of status: VehicleStatus) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ key: String, _ value: Bool?) { if let value { out[key] = value ? "true" : "false" } }
        func put(_ key: String, _ value: Double?) {
            if let value {
                out[key] = value == JavaMath.rint(value) && abs(value) < 9.0e15
                    ? String(JavaMath.truncate(value))
                    : JavaMath.doubleToString(value)
            }
        }
        func put(_ key: String, _ value: String?) { if let value { out[key] = value } }

        put("acAutoMode", status.acAutoMode)
        put("acTempSet", status.acTempSet)
        put("acquisitionTime", status.acquisitionTime)
        put("airConditioner", status.airConditioner)
        put("antitheft", status.antitheft)
        put("avgEnergyConsumption", status.avgEnergyConsumption)
        put("avgFuelConsumption", status.avgFuelConsumption)
        put("batteryPercent", status.batteryPercent)
        put("batteryVoltage", status.batteryVoltage)
        put("cabinClean", status.cabinClean)
        put("cabinTemp", status.cabinTemp)
        put("doorFrontLeft", status.doorFrontLeft)
        put("doorFrontRight", status.doorFrontRight)
        put("doorRearLeft", status.doorRearLeft)
        put("doorRearRight", status.doorRearRight)
        put("doorTrunk", status.doorTrunk)
        put("doorsLocked", status.doorsLocked)
        put("engineState", status.engineState)
        put("evRange", status.evRange)
        put("frontDefroster", status.frontDefroster)
        put("fuelGauge", status.fuelGauge)
        put("fuelRange", status.fuelRange)
        put("fuelVolume", status.fuelVolume)
        put("gear", status.gear)
        put("gpsSwitchOn", status.gpsSwitchOn)
        put("highBeam", status.highBeam)
        put("hood", status.hood)
        put("lowBeam", status.lowBeam)
        put("mileage", status.mileage)
        put("oilAlarm", status.oilAlarm)
        put("powerState", status.powerState)
        put("rearDefroster", status.rearDefroster)
        put("seatHeatDriver", status.seatHeatDriver)
        put("seatHeatPassenger", status.seatHeatPassenger)
        put("seatHeatRearLeft", status.seatHeatRearLeft)
        put("seatHeatRearRight", status.seatHeatRearRight)
        put("seatVentDriver", status.seatVentDriver)
        put("seatVentPassenger", status.seatVentPassenger)
        put("steerWheelHeat", status.steerWheelHeat)
        put("sunroof", status.sunroof)
        put("tboxStatus", status.tboxStatus)
        put("tireAlarmFl", status.tireAlarmFl)
        put("tireAlarmFr", status.tireAlarmFr)
        put("tireAlarmRl", status.tireAlarmRl)
        put("tireAlarmRr", status.tireAlarmRr)
        put("tirePressureFl", status.tirePressureFl)
        put("tirePressureFr", status.tirePressureFr)
        put("tirePressureRl", status.tirePressureRl)
        put("tirePressureRr", status.tirePressureRr)
        put("tireTempFl", status.tireTempFl)
        put("tireTempFr", status.tireTempFr)
        put("tireTempRl", status.tireTempRl)
        put("tireTempRr", status.tireTempRr)
        put("windowFrontLeft", status.windowFrontLeft)
        put("windowFrontRight", status.windowFrontRight)
        put("windowRearLeft", status.windowRearLeft)
        put("windowRearRight", status.windowRearRight)
        put("windshieldHeat", status.windshieldHeat)
        return out
    }

    func fixture(_ name: String) throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("缺少 fixture \(name).json")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(JSONParser.parse(text))
    }

    func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try fixture(name)
        // GwmClient 会先剥离 data 层，这里复刻同一路径
        let payload = root.valueIgnoringCase("data") ?? root
        let actual = Self.fields(of: VehicleStatus.parse(payload))
        let expected = Self.golden[name] ?? [:]
        XCTAssertEqual(actual, expected, "fixture \(name) 与原实现不一致", file: file, line: line)
    }

    func testAllFixturesMatchOriginal() throws {
        for name in ["full", "empty", "rootonly", "actemp_out_of_range", "actemp_divided",
                     "door_case_mismatch", "windows_partial", "values_edge"] {
            try check(name)
        }
    }

    func testGoldenCoverage() {
        // full 场景应解析出足够多的字段，避免基准文件意外为空导致假通过
        XCTAssertGreaterThanOrEqual(Self.golden["full"]?.count ?? 0, 55)
    }
}
