import XCTest
@testable import XiaoHaCore

/// 命令编排的端到端验证：用真实报文驱动，检查下发顺序与结果判定。
final class CommandExecutorTests: XCTestCase {
    /// 构造一个已登录、可下发指令的仓储。
    func makeRepository(_ transport: StubTransport, platform: String = "gtsp")
        -> (GwmRepository, GwmClient) {
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

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exec-\(UUID().uuidString)", isDirectory: true)
        let store = GwmSecureStore(keychain: KeychainStore(service: "t-\(UUID().uuidString)"), directory: directory)
        let repo = GwmRepository(
            store: store,
            client: client,
            preferences: .init(pollEnabled: false, selectedVin: "LSVAA1234567890"),
            emit: { _ in }
        )
        return (repo, client)
    }

    func fastTiming() -> CommandExecutor.Timing {
        CommandExecutor.Timing(verifyInterval: 0.01, verifyTimeout: 0.3,
                               stepGapOnSuccess: 0.01, stepGapOnFailure: 0.01,
                               maxIterationsBeforeUnverifiable: 1)
    }

    /// 锁车时若检测到车窗未关，应自动补发关车窗（保持原实现的链式行为）。
    func testLockChainIncludesWindowClose() async throws {
        var before = VehicleStatus()
        before.doorsLocked = false
        before.windowFrontLeft = true   // 有窗未关
        before.sunroof = true           // 天窗也开着

        let transport = StubTransport()
        transport.on(path: "/app-api/api/v3.0/vehicle/getLastStatus") { _ in
            json("{\"code\":\"0\",\"data\":{\"vehicleStatusInfo\":{\"esclLockSts\":\"1\",\"lfwinposnsts\":\"1\",\"skylightsts\":\"3\"}}}")
        }
        transport.on(path: "/app-api/api/v1.0/vehicle/T5/sendCmd") { _ in json("{\"code\":\"0\",\"data\":{}}") }
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX\"}}") }

        let (repo, _) = makeRepository(transport)
        repo.setCurrentStatus(before)
        let executor = CommandExecutor(repository: repo, timing: fastTiming())

        let expectation = expectation(description: "run finished")
        var result: CommandExecutor.Result?
        executor.run(.lock) { value in
            result = value
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 10)

        // 锁车 + 关车窗 + 关天窗
        XCTAssertEqual(executor.dispatchedControlTypes, ["VEHICLE_LOCK", "WINDOW_CLOSE", "SKYLIGNT_CLOSE"])
        XCTAssertNotNil(result)
    }

    /// 车窗全关时不应补发关车窗，避免多余指令。
    func testLockWithoutExtraStepsWhenAlreadyClosed() async throws {
        var before = VehicleStatus()
        before.doorsLocked = false
        before.windowFrontLeft = false
        before.windowRearLeft = false
        before.sunroof = false

        let transport = StubTransport()
        transport.on(path: "getLastStatus") { _ in
            json("{\"code\":\"0\",\"data\":{\"vehicleStatusInfo\":{\"esclLockSts\":\"1\",\"lfwinposnsts\":\"1\",\"skylightsts\":\"3\"}}}")
        }
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX\"}}") }

        let (repo, _) = makeRepository(transport)
        repo.setCurrentStatus(before)
        let executor = CommandExecutor(repository: repo, timing: fastTiming())

        let expectation = expectation(description: "finished")
        executor.run(.lock) { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 10)

        XCTAssertEqual(executor.dispatchedControlTypes, ["VEHICLE_LOCK"])
    }

    /// 车况未同步时，锁车会连同关车窗、关天窗一起下发（原实现的 else 分支）。
    func testLockWhenStatusUnknownSendsAllSteps() async throws {
        let transport = StubTransport()
        transport.on(path: "getLastStatus") { _ in json("{\"code\":\"0\",\"data\":{}}") }
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX\"}}") }

        let (repo, _) = makeRepository(transport)
        repo.setCurrentStatus(nil)
        let executor = CommandExecutor(repository: repo, timing: fastTiming())

        let expectation = expectation(description: "finished")
        executor.run(.lock) { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 10)

        XCTAssertEqual(executor.dispatchedControlTypes, ["VEHICLE_LOCK", "WINDOW_CLOSE", "SKYLIGNT_CLOSE"])
    }

    /// 远程启动被守卫拦下时不发任何指令。
    func testEngineStartBlockedByGuardDispatchesNothing() async throws {
        var low = VehicleStatus()
        low.engineState = "0"
        low.batteryPercent = 8

        let transport = StubTransport()
        let (repo, _) = makeRepository(transport)
        repo.setCurrentStatus(low)
        let executor = CommandExecutor(repository: repo, timing: fastTiming())

        let expectation = expectation(description: "finished")
        var message: String?
        executor.run(.engineStart) { result in
            message = result.message
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 5)

        XCTAssertTrue(executor.dispatchedControlTypes.isEmpty)
        XCTAssertEqual(message, "电量仅剩 8%，低于 15%，不建议远程启动")
    }

    /// 车况确认变化 → 成功。
    func testSuccessWhenStatusConfirmsChange() async throws {
        var before = VehicleStatus()
        before.doorsLocked = false

        let transport = StubTransport()
        // esclLockSts 是"未锁位"：0 表示已锁（与 Java 的 toBoolInverted 一致）
        transport.on(path: "getLastStatus") { _ in
            json("{\"code\":\"0\",\"data\":{\"vehicleStatusInfo\":{\"esclLockSts\":\"0\"}}}")
        }
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX\"}}") }

        let (repo, _) = makeRepository(transport)
        repo.setCurrentStatus(before)
        let executor = CommandExecutor(repository: repo, timing: fastTiming())

        let expectation = expectation(description: "finished")
        var result: CommandExecutor.Result?
        executor.run(.lock) { value in
            result = value
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 10)

        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.verified, true)
        XCTAssertTrue(result?.message.hasPrefix("锁车成功") == true, result?.message ?? "")
    }

    /// 车况始终没变化 → 超时后报未生效。
    func testTimeoutReportsNotEffective() async throws {
        var before = VehicleStatus()
        before.doorsLocked = false
        before.sunroof = false
        before.windowFrontLeft = true   // 避免触发补发，专注超时路径

        let transport = StubTransport()
        // 一直返回未锁
        transport.on(path: "getLastStatus") { _ in
            json("{\"code\":\"0\",\"data\":{\"vehicleStatusInfo\":{\"esclLockSts\":\"0\"}}}")
        }
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX\"}}") }

        let (repo, _) = makeRepository(transport)
        repo.setCurrentStatus(before)
        let executor = CommandExecutor(repository: repo, timing: fastTiming())

        let expectation = expectation(description: "finished")
        var result: CommandExecutor.Result?
        executor.run(.unlock) { value in
            result = value
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 15)

        XCTAssertEqual(result?.success, false)
        XCTAssertTrue(result?.message.contains("未生效") == true, result?.message ?? "")
    }
}
