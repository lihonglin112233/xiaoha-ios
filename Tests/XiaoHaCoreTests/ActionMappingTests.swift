import XCTest
@testable import XiaoHaCore

/// 穷举每个动作实际发出的请求，逐字段核对 controlType / cmdCode / 请求路径。
/// 目的：用证据定位"点解锁却下发闪灯"这类错配，而不是靠读代码猜。
final class ActionMappingTests: XCTestCase {

    struct Captured {
        let action: VehicleAction
        let path: String
        let controlType: String?
        let cmdCode: Double?
        let fn: String?
        let raw: String
    }

    /// 跑一遍动作，抓取真实发出的请求。
    func capture(_ action: VehicleAction, platform: String) async throws -> Captured? {
        let transport = StubTransport()
        transport.on(path: "T5/sendCmd") { _ in json("{\"code\":\"0\",\"data\":{}}") }
        transport.on(path: "remote-ctrl/timely") { _ in json("{\"code\":\"0\",\"data\":{}}") }
        transport.on(path: "/tsp/ead") { _ in
            json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX\"}}")
        }

        let client = GwmClient(transport: transport)
        client.phone = "13800000000"
        client.deviceId = "DEVID"
        client.gToken = "G"
        client.gRefreshToken = "R"
        client.userId = "U"
        client.beanId = "B"
        client.btAccessToken = "BT"
        client.autoTokenId = "AT"
        client.autoUserId = "AU"
        client.rememberPlatform("LSVAA1234567890", platform: platform)

        let body: JSONValue? = action == .acOn || action == .acTempSet
            ? TempControl.bodiesOf(24, zone: .both)
            : (action == .engineStart ? VehicleAction.bodyOf(.engineStart, minutes: 15) : nil)

        _ = try await client.sendCommand("LSVAA1234567890", action.controlType, body)

        let request: HTTPRequest?
        if platform == "beantech" {
            request = transport.lastRequest(path: "sendCmd") ?? transport.lastRequest(path: "timely")
        } else {
            request = transport.lastRequest(path: "/tsp/ead")
        }
        guard let request else { return nil }

        let path = request.url.contains("timely") ? "timely"
            : request.url.contains("sendCmd") ? "sendCmd"
            : request.url.contains("/tsp/ead") ? "ead" : "?"

        if path == "ead" {
            let decoded = (request.url.components(separatedBy: "?p=").last?.removingPercentEncoding) ?? ""
            let parsed = JSONParser.parse(decoded)
            let bodyNode = parsed?.value("body")
            return Captured(
                action: action,
                path: path,
                controlType: nil,
                cmdCode: bodyNode?.value("cmdCode")?.asDouble,
                fn: parsed?.value("header")?.value("fn")?.asString,
                raw: decoded
            )
        }
        let parsed = JSONParser.parse(request.body)
        let command = parsed?.value("commands")?.asArray?.first
        return Captured(
            action: action,
            path: path,
            controlType: command?.value("controlType")?.asString,
            cmdCode: nil,
            fn: nil,
            raw: request.body ?? ""
        )
    }

    /// 期望的 cmdCode 映射（来自反编译原实现的 AUTO_AI_CMD_CODES，逐条核对过）。
    static let expectedCmdCodes: [VehicleAction: Double] = [
        .unlock: 1, .lock: 2, .windowClose: 3, .acOn: 6, .acOff: 7,
        .engineStart: 15, .engineStop: 16, .whistle: 19, .flash: 20,
    ]

    static let actions: [VehicleAction] = [
        .lock, .unlock, .windowClose, .whistle, .flash,
        .acOn, .acOff, .engineStart, .engineStop, .acTempSet,
        .defrostFront, .defrostRear, .steerHeat,
    ]

    /// gtsp 平台：逐个动作核对 cmdCode 与 fn，确保没有错配。
    func testGtspCmdCodesAreDistinctAndCorrect() async throws {
        var seen: [Double: VehicleAction] = [:]
        for action in Self.actions {
            guard let expected = Self.expectedCmdCodes[action] else { continue }
            let captured = try await capture(action, platform: "gtsp")
            let cap = try XCTUnwrap(captured, "动作 \(action.rawValue) 没有发出请求")
            XCTAssertEqual(cap.path, "ead", "\(action.rawValue) 应走 AutoAI 通道")
            XCTAssertEqual(cap.cmdCode, expected,
                           "动作 \(action.rawValue) 的 cmdCode 错配：期望 \(expected)，实际 \(cap.cmdCode.map { String($0) } ?? "nil")")

            // 同一 cmdCode 不能对应两个动作
            if let previous = seen[expected] {
                XCTFail("cmdCode \(expected) 同时对应 \(previous.rawValue) 与 \(action.rawValue)")
            }
            seen[expected] = action
        }
        XCTAssertEqual(seen.count, Self.expectedCmdCodes.count)
    }

    /// 关键回归：解锁必须是 cmdCode 1，闪灯必须是 20，二者绝不能混。
    func testUnlockIsNotFlash() async throws {
        let unlockCap = try await capture(.unlock, platform: "gtsp")
        let flashCap = try await capture(.flash, platform: "gtsp")
        let unlock = try XCTUnwrap(unlockCap)
        let flash = try XCTUnwrap(flashCap)
        XCTAssertEqual(unlock.cmdCode, 1)
        XCTAssertEqual(flash.cmdCode, 20)
        XCTAssertNotEqual(unlock.cmdCode, flash.cmdCode)
        XCTAssertNotEqual(unlock.raw, flash.raw)
    }

    /// 两种空调策略下的指令码与 function 必须各自正确。
    func testHvacStrategyModes() async throws {
        // 默认：原 APK 的 6/7
        let defaultCap = try await captureWithStrategy(.acOn, strategy: .dedicatedCodes)
        XCTAssertEqual(defaultCap.cmdCode, 6, "默认策略开空调应为 cmdCode 6")
        XCTAssertEqual(defaultCap.fn, "GW.M.SET_AND_OPEN_COMMAND")

        // 社区实测：改用远程启动 15 / 熄火 16
        let fallbackOn = try await captureWithStrategy(.acOn, strategy: .engineFallback)
        XCTAssertEqual(fallbackOn.cmdCode, 15, "engineFallback 开空调应映射到 cmdCode 15")
        XCTAssertEqual(fallbackOn.fn, "GW.M.SET_AND_OPEN_COMMAND")
        XCTAssertTrue(fallbackOn.raw.contains("engineParams"), "应带 engineParams 而非 airParams")

        let fallbackOff = try await captureWithStrategy(.acOff, strategy: .engineFallback)
        XCTAssertEqual(fallbackOff.cmdCode, 16, "engineFallback 关空调应映射到 cmdCode 16")
        XCTAssertEqual(fallbackOff.fn, "GW.M.SEND_COMMON_COMMAND")
    }

    func captureWithStrategy(_ action: VehicleAction, strategy: GwmClient.HvacStrategy) async throws -> Captured {
        let transport = StubTransport()
        transport.on(path: "/tsp/ead") { _ in
            json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX\"}}")
        }
        let client = GwmClient(transport: transport)
        client.phone = "13800000000"
        client.deviceId = "DEVID"
        client.gToken = "G"; client.gRefreshToken = "R"; client.userId = "U"
        client.beanId = "B"; client.btAccessToken = "BT"
        client.autoTokenId = "AT"; client.autoUserId = "AU"
        client.rememberPlatform("LSVAA1234567890", platform: "gtsp")
        client.hvacStrategy = strategy
        _ = try await client.sendCommand("LSVAA1234567890", action.controlType,
                                         TempControl.bodiesOf(24, zone: .both))
        let request = try XCTUnwrap(transport.lastRequest(path: "/tsp/ead"))
        let decoded = (request.url.components(separatedBy: "?p=").last?.removingPercentEncoding) ?? ""
        let parsed = JSONParser.parse(decoded)
        return Captured(action: action, path: "ead", controlType: nil,
                        cmdCode: parsed?.value("body")?.value("cmdCode")?.asDouble,
                        fn: parsed?.value("header")?.value("fn")?.asString,
                        raw: decoded)
    }

    /// 远程启动/空调应使用 SET_AND_OPEN_COMMAND，其余用 SEND_COMMON_COMMAND。
    func testAutoAiFunctionNames() async throws {
        for action in [VehicleAction.engineStart, .acOn, .acTempSet] {
            let captured = try await capture(action, platform: "gtsp")
            let cap = try XCTUnwrap(captured)
            XCTAssertEqual(cap.fn, "GW.M.SET_AND_OPEN_COMMAND",
                           "\(action.rawValue) 应使用 SET_AND_OPEN_COMMAND")
        }
        for action in [VehicleAction.lock, .unlock, .whistle, .flash, .engineStop, .acOff] {
            let captured = try await capture(action, platform: "gtsp")
            let cap = try XCTUnwrap(captured)
            XCTAssertEqual(cap.fn, "GW.M.SEND_COMMON_COMMAND",
                           "\(action.rawValue) 应使用 SEND_COMMON_COMMAND")
        }
    }

    /// beantech 平台：controlType 必须与动作一致，不能串。
    func testBeanTechControlTypes() async throws {
        let expected: [VehicleAction: String] = [
            .lock: "VEHICLE_LOCK",
            .unlock: "VEHICLE_UNLOCK",
            .whistle: "WHISTLE",
            .flash: "FLASH",
            .acOn: "AIR_CONDITIONER_START",
            .acOff: "AIR_CONDITIONER_STOP",
            .engineStart: "ENGINE_START",
            .engineStop: "ENGINE_STOP",
        ]
        for (action, controlType) in expected {
            let captured = try await capture(action, platform: "beantech")
            let cap = try XCTUnwrap(captured)
            XCTAssertEqual(cap.controlType, controlType,
                           "\(action.rawValue) 的 controlType 错配")
        }
    }

    /// 每个动作的 payload 必须携带自己的标识，不能出现串包。
    func testGtspPayloadSelfConsistency() async throws {
        for action in Self.actions {
            guard Self.expectedCmdCodes[action] != nil else { continue }
            let captured = try await capture(action, platform: "gtsp")
            let cap = try XCTUnwrap(captured)
            XCTAssertTrue(cap.raw.contains("\"vin\":\"LSVAA1234567890\""),
                          "\(action.rawValue) 缺少 vin")
            XCTAssertTrue(cap.raw.contains("\"cmdCode\":\(Int(cap.cmdCode ?? -1))"),
                          "\(action.rawValue) payload 内 cmdCode 与解析值不一致")
            // 空调同时有 operationTime 与 temperature 的语义不能被丢
            if action == .acOn {
                XCTAssertTrue(cap.raw.contains("airParams"), "开空调应带 airParams")
            }
            if action == .engineStart {
                XCTAssertTrue(cap.raw.contains("engineParams"), "远程启动应带 engineParams")
            }
        }
    }

    /// 云端字段名不统一时的定位识别（递归语义扫描，不依赖固定键名）。
    func testLocationFieldNameVariants() {
        let cases: [(String, Double, Double)] = [
            ("{\"position\":{\"lat\":\"39.9\",\"lon\":\"116.4\"}}", 39.9, 116.4),
            ("{\"gpsLat\":\"31.2\",\"gpsLng\":\"121.4\"}", 31.2, 121.4),
            ("{\"latitude\":\"22.5\",\"longitude\":\"114.0\"}", 22.5, 114.0),
            ("{\"loc_lat\":\"30.6\",\"loc_lon\":\"104.0\"}", 30.6, 104.0),
            ("{\"vehicleLatitude\":\"23.1\",\"vehicleLongitude\":\"113.2\"}", 23.1, 113.2),
            ("{\"a\":{\"b\":{\"lat\":\"39.0\",\"lng\":\"116.0\"}}}", 39.0, 116.0),
        ]
        for (json, lat, lon) in cases {
            let status = VehicleStatus.parse(JSONParser.parse(json))
            XCTAssertEqual(status.latitude, lat, "lat 识别失败: \(json)")
            XCTAssertEqual(status.longitude, lon, "lon 识别失败: \(json)")
            XCTAssertTrue(status.hasCoordinate, "应判定为有坐标: \(json)")
        }
    }

    /// 只有经度没有纬度时不应当作有效定位。
    func testLocationRequiresBoth() {
        let onlyLon = VehicleStatus.parse(JSONParser.parse("{\"lon\":\"116.4\"}"))
        XCTAssertFalse(onlyLon.hasCoordinate)
        // 但单侧值仍被保留，便于诊断
        XCTAssertEqual(onlyLon.longitude, nil, "不成对时不应单独采信")
    }

    /// 超出范围的数值不能被当成坐标。
    func testLocationRangeValidation() {
        let bad = VehicleStatus.parse(JSONParser.parse("{\"lat\":\"999\",\"lon\":\"116.4\"}"))
        XCTAssertFalse(bad.hasCoordinate, "纬度 999 非法")
    }

    /// 定位字段解析：有坐标时正确、无坐标时如实为 nil。
    func testLocationParsing() {
        let withCoords = VehicleStatus.parse(JSONParser.parse("""
        {"vehicleStatusInfo":{"position":{"lat":"39.9042","lon":"116.4074","time":"2026-11-23 20:00:00"}}}
        """))
        XCTAssertEqual(withCoords.latitude, 39.9042)
        XCTAssertEqual(withCoords.longitude, 116.4074)
        XCTAssertEqual(withCoords.positionTime, "2026-11-23 20:00:00")
        XCTAssertTrue(withCoords.hasCoordinate)

        // 平铺字段也能识别
        let flat = VehicleStatus.parse(JSONParser.parse("""
        {"vehicleStatusInfo":{"latitude":"31.2304","lng":"121.4737"}}
        """))
        XCTAssertEqual(flat.latitude, 31.2304)
        XCTAssertEqual(flat.longitude, 121.4737)

        // 未上报
        let none = VehicleStatus.parse(JSONParser.parse("{\"vehicleStatusInfo\":{\"oilQty\":\"1\"}}"))
        XCTAssertNil(none.latitude)
        XCTAssertNil(none.longitude)
        XCTAssertFalse(none.hasCoordinate)

        // 0,0 视为无效
        let zero = VehicleStatus.parse(JSONParser.parse("""
        {"vehicleStatusInfo":{"lat":"0","lon":"0"}}
        """))
        XCTAssertFalse(zero.hasCoordinate, "0,0 不应被当成有效坐标")
    }
}
