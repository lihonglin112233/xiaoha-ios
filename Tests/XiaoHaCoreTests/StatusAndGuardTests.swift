import XCTest
@testable import XiaoHaCore

final class VehicleStatusParsingTests: XCTestCase {
    func fixture(_ name: String) throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("缺少 fixture \(name).json")
        }
        return try XCTUnwrap(JSONParser.parse(try String(contentsOf: url, encoding: .utf8)))
    }

    func testParsesFullPayload() throws {
        // 与 Java 基准测试共用同一份报文；VehicleStatus.parse 接收 data 层
        let root = try fixture("full")
        let data = try XCTUnwrap(root.value("data"))
        let status = VehicleStatus.parse(data)

        XCTAssertEqual(status.acquisitionTime, "2026-11-22 21:00:00")
        XCTAssertEqual(status.tboxStatus, "1")
        XCTAssertEqual(status.fuelGauge, "58")
        XCTAssertEqual(status.fuelVolume, 42.5)
        XCTAssertEqual(status.fuelRange, 380)
        XCTAssertEqual(status.batteryPercent, 62)
        XCTAssertEqual(status.mileage, 12345.6)
        XCTAssertEqual(status.evRange, 310)
        XCTAssertEqual(status.avgFuelConsumption, 7.8)
        XCTAssertEqual(status.avgEnergyConsumption, 13.4)
        XCTAssertEqual(status.batteryVoltage, 12.4)
        XCTAssertEqual(status.cabinTemp, 22.5)
        // 245 是 24.5℃ 的分度值
        XCTAssertEqual(status.acTempSet, 24.5)
        XCTAssertEqual(status.engineState, "2")
        XCTAssertEqual(status.engineText(), "已启动")
        XCTAssertTrue(status.isEngineRunning())
        XCTAssertTrue(status.isParked())
        // esclLockSts=1 表示未锁（取反）
        XCTAssertEqual(status.doorsLocked, false)
        XCTAssertEqual(status.doorFrontLeft, false)
        XCTAssertEqual(status.doorFrontRight, true)
        XCTAssertEqual(status.doorTrunk, false)
        XCTAssertTrue(status.hasOpenDoor())
        // 车窗 1 表示关闭
        XCTAssertEqual(status.windowFrontLeft, false)
        XCTAssertEqual(status.windowFrontRight, true)
        XCTAssertEqual(status.sunroof, false)
        XCTAssertTrue(status.hasOpenWindow())
        XCTAssertEqual(status.airConditioner, true)
        XCTAssertEqual(status.acAutoMode, true)
        XCTAssertEqual(status.frontDefroster, true)
        XCTAssertEqual(status.rearDefroster, false)
        XCTAssertEqual(status.steerWheelHeat, true)
        XCTAssertEqual(status.lowBeam, true)
        XCTAssertEqual(status.highBeam, false)
        XCTAssertEqual(status.seatHeatDriver, true)
        XCTAssertEqual(status.tirePressureFl, 2.4)
        XCTAssertEqual(status.tirePressureRr, 2.5)
        XCTAssertEqual(status.tireAlarmFl, true)
        XCTAssertEqual(status.tireAlarmFr, false)
        XCTAssertEqual(status.tireTempFl, 31)
        XCTAssertFalse(status.isEmpty())
    }

    func testAcTempOutOfRangeIsDropped() {
        let status = VehicleStatus.parse(JSONParser.parse("{\"vehicleStatusInfo\":{\"acTemp\":\"500\"}}"))
        XCTAssertNil(status.acTempSet, "超过 40℃ 的读数应被丢弃")
        let tooLow = VehicleStatus.parse(JSONParser.parse("{\"vehicleStatusInfo\":{\"setTemp\":\"5\"}}"))
        XCTAssertNil(tooLow.acTempSet)
    }

    func testParseValueRejectsPlaceholders() {
        XCTAssertNil(VehicleStatus.parseValue(.string("--")))
        XCTAssertNil(VehicleStatus.parseValue(.string("null")))
        XCTAssertNil(VehicleStatus.parseValue(.string("")))
        XCTAssertEqual(VehicleStatus.parseValue(.string("2.5,bar")), 2.5)
        XCTAssertEqual(VehicleStatus.parseValue(.number(7)), 7)
    }

    func testEmptyAndUnknownFields() {
        let empty = VehicleStatus.parse(JSONParser.parse("{}"))
        XCTAssertTrue(empty.isEmpty())
        XCTAssertEqual(empty.engineText(), "未知")
        XCTAssertEqual(empty.securitySummary(), "门锁未知")
        // 缺失字段不应误判为已关车窗
        XCTAssertFalse(empty.hasOpenWindow())
        XCTAssertFalse(empty.hasOpenDoor())
    }

    func testRootLevelFallbacks() {
        let payload = """
        {"acquisitionTime":"t1","gpsSwitchOn":"1","tboxStatus":"9","oilQty":"10","engineSts":"0"}
        """
        let status = VehicleStatus.parse(JSONParser.parse(payload))
        XCTAssertEqual(status.acquisitionTime, "t1")
        XCTAssertEqual(status.gpsSwitchOn, "1")
        XCTAssertEqual(status.tboxStatus, "9")
        XCTAssertEqual(status.fuelGauge, "10")
        XCTAssertEqual(status.engineState, "0")
        XCTAssertFalse(status.isEngineRunning())
        XCTAssertEqual(status.engineText(), "未启动")
    }

    func testSecuritySummary() {
        var status = VehicleStatus()
        status.doorsLocked = true
        status.windowFrontLeft = true
        status.tireAlarmRl = true
        XCTAssertEqual(status.securitySummary(), "已锁车 · 有车窗未关 · 胎压异常")
    }
}

final class GuardTests: XCTestCase {
    func testEngineStartRules() {
        XCTAssertFalse(EngineGuard.canStart(nil).allowed)

        var noEngineField = VehicleStatus()
        noEngineField.mileage = 1
        XCTAssertFalse(EngineGuard.canStart(noEngineField).allowed)

        var running = VehicleStatus()
        running.engineState = "2"
        XCTAssertFalse(EngineGuard.canStart(running).allowed)
        XCTAssertTrue(EngineGuard.canStop(running).allowed)

        var openDoor = VehicleStatus()
        openDoor.engineState = "0"
        openDoor.doorFrontLeft = true
        let doorVerdict = EngineGuard.canStart(openDoor)
        XCTAssertTrue(doorVerdict.allowed)
        XCTAssertTrue(doorVerdict.needsConfirm)

        var lowBattery = VehicleStatus()
        lowBattery.engineState = "0"
        lowBattery.batteryPercent = 12
        XCTAssertFalse(EngineGuard.canStart(lowBattery).allowed)
        XCTAssertTrue(EngineGuard.canStart(lowBattery).message.contains("12%"))

        var lowVoltage = VehicleStatus()
        lowVoltage.engineState = "0"
        lowVoltage.batteryPercent = 50
        lowVoltage.batteryVoltage = 11.2
        XCTAssertFalse(EngineGuard.canStart(lowVoltage).allowed)

        var ok = VehicleStatus()
        ok.engineState = "0"
        ok.batteryPercent = 60
        ok.batteryVoltage = 12.4
        let okVerdict = EngineGuard.canStart(ok)
        XCTAssertTrue(okVerdict.allowed)
        XCTAssertFalse(okVerdict.needsConfirm)
    }

    func testEngineStopRules() {
        var stopped = VehicleStatus()
        stopped.engineState = "0"
        XCTAssertFalse(EngineGuard.canStop(stopped).allowed)
        XCTAssertTrue(EngineGuard.canStop(nil).allowed)
    }

    func testHvacPlatformSupport() {
        XCTAssertTrue(HvacGuard.platformSupportsAux(nil))
        XCTAssertTrue(HvacGuard.platformSupportsAux(""))
        XCTAssertFalse(HvacGuard.platformSupportsAux("gtsp"))
        XCTAssertFalse(HvacGuard.platformSupportsAux("navinfo"))
        XCTAssertTrue(HvacGuard.platformSupportsAux("beantech"))
        XCTAssertFalse(HvacGuard.canTurnOn(nil).allowed)
        XCTAssertEqual(HvacGuard.unsupportedPlatformText(nil),
                       "当前车机平台（未知）未开放除霜/方向盘加热指令，可改用开空调调节车内温度")
    }
}

final class TempControlTests: XCTestCase {
    func testNormalizeClampsAndRounds() {
        XCTAssertEqual(TempControl.normalize(16), 17)
        XCTAssertEqual(TempControl.normalize(40), 31)
        XCTAssertEqual(TempControl.normalize(24.3), 24.5)
        XCTAssertEqual(TempControl.normalize(24.2), 24)
        XCTAssertEqual(TempControl.normalize(24.75), 25)
    }

    func testStepping() {
        XCTAssertEqual(TempControl.up(31), 31)
        XCTAssertEqual(TempControl.down(17), 17)
        XCTAssertTrue(TempControl.atMax(30.8))
        XCTAssertTrue(TempControl.atMin(17.2))
        XCTAssertEqual(TempControl.up(23.5), 24)
    }

    func testFormatting() {
        XCTAssertEqual(TempControl.format(24), "24°C")
        XCTAssertEqual(TempControl.format(24.5), "24.5°C")
        XCTAssertEqual(TempControl.format(24, fahrenheit: true), "75°F")
        XCTAssertEqual(TempControl.labelOf(24), "调温至 24°C")
    }

    func testBodies() {
        // normalize(24.4) = 24.5，Java Math.round(24.5) = 25
        let body = TempControl.bodiesOf(24.4, zone: .both)
        XCTAssertEqual(body.value("allowStartEng")?.asDouble, 1)
        XCTAssertEqual(body.value("operationTime")?.asDouble, 600)
        XCTAssertEqual(body.value("temperature")?.asDouble, 25)
        XCTAssertEqual(TempControl.Zone.both.next, .driver)
        XCTAssertEqual(TempControl.Zone.driver.next, .passenger)
        XCTAssertEqual(TempControl.Zone.passenger.next, .both)
        XCTAssertEqual(TempControl.Zone.passenger.label, "副驾")
    }
}
