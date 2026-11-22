import XCTest
@testable import XiaoHaCore

final class StatusAlertCenterTests: XCTestCase {
    func status(locked: Bool?, windowOpen: Bool?, trunk: Bool?, engine: String?, ac: Bool?,
                battery: Double? = nil, range: Double? = nil) -> VehicleStatus {
        var status = VehicleStatus()
        status.doorsLocked = locked
        status.windowFrontLeft = windowOpen
        status.doorTrunk = trunk
        status.engineState = engine
        status.airConditioner = ac
        status.batteryPercent = battery
        status.fuelRange = range
        return status
    }

    func testFirstSnapshotProducesNoAlerts() {
        let center = StatusAlertCenter()
        let result = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false))
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(center.unreadCount, 0)
    }

    func testLockAndWindowAlerts() {
        let center = StatusAlertCenter()
        _ = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false))
        let alerts = center.onStatusUpdated(status(locked: false, windowOpen: true, trunk: false, engine: "0", ac: false))

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[0].item, "门锁")
        XCTAssertEqual(alerts[0].text, "车辆已解锁")
        XCTAssertFalse(alerts[0].good)
        XCTAssertEqual(alerts[1].item, "车窗")
        XCTAssertEqual(alerts[1].text, "检测到车窗被打开")
        XCTAssertFalse(alerts[1].good)
        XCTAssertEqual(center.unreadCount, 2)
    }

    func testEngineAndAcAlertsAreGoodWhenOn() {
        let center = StatusAlertCenter()
        _ = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false))
        let alerts = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "2", ac: true))
        XCTAssertEqual(alerts.map(\.item), ["发动机", "空调"])
        XCTAssertTrue(alerts.allSatisfy(\.good))
        XCTAssertEqual(alerts[0].text, "发动机已启动")
        XCTAssertEqual(alerts[1].text, "空调已开启")
    }

    /// 电量跨过 30/20/10 的整十档才提醒，且只在下降时提醒。
    func testBatteryThresholds() {
        let center = StatusAlertCenter()
        _ = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false, battery: 35))
        let alerts = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false, battery: 28))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].item, "电量")
        XCTAssertEqual(alerts[0].text, "电量已低于 30%（当前 28%）")

        // 同一档内变化不提醒
        let none = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false, battery: 27))
        XCTAssertTrue(none.isEmpty)

        // 回升不提醒
        let up = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false, battery: 45))
        XCTAssertTrue(up.isEmpty)
    }

    func testFuelRangeThresholds() {
        let center = StatusAlertCenter()
        _ = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false, range: 130))
        let alerts = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false, range: 88))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].item, "续航")
        XCTAssertEqual(alerts[0].text, "续航不足 100 km（当前 88 km）")
    }

    func testNilStatusDoesNotCrashOrAlert() {
        let center = StatusAlertCenter()
        XCTAssertTrue(center.onStatusUpdated(nil).isEmpty)
        XCTAssertTrue(center.onStatusUpdated(nil).isEmpty)
    }

    func testClearUnread() {
        let center = StatusAlertCenter()
        _ = center.onStatusUpdated(status(locked: true, windowOpen: false, trunk: false, engine: "0", ac: false))
        _ = center.onStatusUpdated(status(locked: false, windowOpen: false, trunk: false, engine: "0", ac: false))
        XCTAssertEqual(center.unreadCount, 1)
        center.clearUnread()
        XCTAssertEqual(center.unreadCount, 0)
    }
}

final class ChatCommandBridgeTests: XCTestCase {
    func testBasicKeywords() {
        XCTAssertEqual(ChatCommandBridge.parse("帮我锁车")?.action, .lock)
        XCTAssertEqual(ChatCommandBridge.parse("锁门")?.action, .lock)
        XCTAssertEqual(ChatCommandBridge.parse("解锁一下")?.action, .unlock)
        XCTAssertEqual(ChatCommandBridge.parse("关车窗")?.action, .windowClose)
        XCTAssertEqual(ChatCommandBridge.parse("远程熄火")?.action, .engineStop)
        XCTAssertEqual(ChatCommandBridge.parse("鸣笛找车")?.action, .whistle)
        XCTAssertEqual(ChatCommandBridge.parse("闪一下灯")?.action, .flash)
        XCTAssertEqual(ChatCommandBridge.parse("前除霜")?.action, .defrostFront)
        XCTAssertEqual(ChatCommandBridge.parse("打开方向盘加热")?.action, .steerHeat)
    }

    func testEngineStartDefaultsTo15Minutes() {
        let parsed = ChatCommandBridge.parse("远程启动")
        XCTAssertEqual(parsed?.action, .engineStart)
        XCTAssertEqual(parsed?.minutes, 15)
    }

    func testAcWithTemperature() {
        let parsed = ChatCommandBridge.parse("开空调 24度")
        XCTAssertEqual(parsed?.action, .acTempSet)
        XCTAssertEqual(parsed?.temp, 24)
        // 纯开空调不带温度
        let plain = ChatCommandBridge.parse("开空调")
        XCTAssertEqual(plain?.action, .acOn)
        XCTAssertNil(plain?.temp)
    }

    /// 关键词优先级：先命中的规则胜出。
    func testPriority() {
        // 同时含"熄火"和"启动"时，"熄火"先判定
        XCTAssertEqual(ChatCommandBridge.parse("熄火再启动")?.action, .engineStop)
        // 含"开空调"时按空调处理，不落到后面的温度规则
        XCTAssertEqual(ChatCommandBridge.parse("开空调 26 度")?.action, .acTempSet)
    }

    func testTemperatureFallback() {
        let parsed = ChatCommandBridge.parse("调到 22")
        XCTAssertEqual(parsed?.action, .acTempSet)
        XCTAssertEqual(parsed?.temp, 22)
    }

    func testOutOfRangeTemperatureIgnored() {
        XCTAssertNil(ChatCommandBridge.parse("设成 15 度"))
        XCTAssertNil(ChatCommandBridge.parse("设成 40 度"))
    }

    func testUnknownAndEmpty() {
        XCTAssertNil(ChatCommandBridge.parse(""))
        XCTAssertNil(ChatCommandBridge.parse("   "))
        XCTAssertNil(ChatCommandBridge.parse("今天天气怎么样"))
    }
}

final class PluginPersistTests: XCTestCase {
    func testSessionCodecRoundTrip() throws {
        var codec = SessionCodec()
        let client = GwmClient(transport: StubTransport())
        client.phone = "13800000000"
        client.deviceId = "DEVID"
        client.gToken = "G"
        client.gRefreshToken = "R"
        client.userId = "U"
        client.beanId = "B"
        client.btAccessToken = "BT"
        client.autoTokenId = "AT"
        client.autoUserId = "AU"
        client.rememberPlatform("LSVAA1", platform: "gtsp")

        let payload = GwmCrypto.encodeDotnetJSON(client.toStateMap())
        let wrapped = SessionCodec.wrap(payload)
        let restored = try XCTUnwrap(codec.decode(wrapped))
        XCTAssertEqual(restored.gToken, "G")
        XCTAssertEqual(restored.autoTokenId, "AT")
        XCTAssertTrue(restored.isLoggedIn)
        XCTAssertEqual(restored.cachedPlatform("LSVAA1"), "gtsp")
        XCTAssertNil(codec.lastError)
    }

    /// 文案与原实现逐条对齐（已用反编译后的 SessionCodec 实测确认）。
    func testSessionCodecRejectsCorruptedPayload() {
        var codec = SessionCodec()
        XCTAssertNil(codec.decode(nil))
        XCTAssertNil(codec.lastError)
        XCTAssertNil(codec.decode(""))
        XCTAssertNil(codec.decode("not json"))
        XCTAssertEqual(codec.lastError, "登录凭据已失效（IllegalArgumentException），需要重新登录")
        XCTAssertNil(codec.decode("{}"))
        XCTAssertEqual(codec.lastError, "本地凭据缺少刷新令牌，需要重新登录")
        XCTAssertNil(codec.decode("[]"))
        XCTAssertEqual(codec.lastError, "登录凭据格式异常，需要重新登录")
        XCTAssertNil(codec.decode("\"hello\""))
        XCTAssertEqual(codec.lastError, "登录凭据格式异常，需要重新登录")
    }

    func testSessionCodecRequiresRefreshToken() {
        var codec = SessionCodec()
        let noRefresh = "{\"v\":2,\"data\":{\"phone\":\"1\",\"g_token\":\"G\",\"user_id\":\"U\"}}"
        XCTAssertNil(codec.decode(noRefresh))
        XCTAssertEqual(codec.lastError, "本地凭据缺少刷新令牌，需要重新登录")
    }

    func testSecureStorePersistsAcrossInstances() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xiaoha-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = GwmClient(transport: StubTransport())
        client.gToken = "G"
        client.gRefreshToken = "R"
        client.userId = "U"
        client.beanId = "B"
        client.btAccessToken = "BT"
        client.autoTokenId = "AT"
        client.autoUserId = "AU"

        let first = GwmSecureStore(keychain: KeychainStore(service: "test-\(UUID().uuidString)"), directory: directory)
        XCTAssertTrue(first.save(client))
        XCTAssertTrue(first.hasCredentials())

        // 新实例从磁盘恢复，模拟冷启动
        let second = GwmSecureStore(keychain: KeychainStore(service: "test-other"), directory: directory)
        let restored = try XCTUnwrap(second.load())
        XCTAssertEqual(restored.gToken, "G")
        XCTAssertTrue(restored.isLoggedIn)

        second.clear()
        XCTAssertFalse(second.hasCredentials())
    }

    func testWidgetSnapshotRoundTrip() {
        var status = VehicleStatus()
        status.doorsLocked = true
        status.batteryPercent = 62
        status.fuelRange = 380
        status.engineState = "2"
        status.airConditioner = true
        let vehicle = GwmVehicle(vin: "LSVAA1234567890", modelName: "H6", nickname: "小黑", platform: "gtsp")
        let snapshot = WidgetSnapshot(status: status, vehicle: vehicle, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(snapshot.vehicleName, "小黑")
        XCTAssertEqual(snapshot.battery, 62)
        XCTAssertEqual(snapshot.range, 380)
        XCTAssertTrue(snapshot.engineRunning)
        XCTAssertTrue(snapshot.locked == true)

        let data = try? JSONEncoder().encode(snapshot)
        let decoded = WidgetSnapshot.decoded(data)
        XCTAssertEqual(decoded?.vehicleName, "小黑")
        XCTAssertEqual(decoded?.battery, 62)
        XCTAssertEqual(WidgetSnapshot.decoded(nil)?.vehicleName, nil)
    }
}
