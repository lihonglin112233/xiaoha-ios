import XCTest
@testable import XiaoHaCore

/// 记录请求并回放响应的传输层，用于端到端验证协议行为。
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Route {
        let match: (HTTPRequest) -> Bool
        let response: (HTTPRequest) -> HTTPResponse
    }

    private var routes: [Route] = []
    private(set) var requests: [HTTPRequest] = []
    private let lock = NSLock()

    init() {}

    func on(_ description: String, _ match: @escaping (HTTPRequest) -> Bool,
            _ respond: @escaping (HTTPRequest) -> HTTPResponse) {
        routes.append(Route(match: match, response: respond))
    }

    func on(path: String, _ respond: @escaping (HTTPRequest) -> HTTPResponse) {
        on(path, { $0.url.contains(path) }, respond)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        let route = routes.first { $0.match(request) }
        lock.unlock()
        guard let route else {
            return HTTPResponse(statusCode: 404, body: "no route for \(request.url)")
        }
        return route.response(request)
    }

    func lastRequest(path: String) -> HTTPRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last { $0.url.contains(path) }
    }
}

func json(_ text: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, body: text)
}

final class ClientFlowTests: XCTestCase {
    /// 构造一个已完成登录的客户端，模拟平台为 gtsp（走 AutoAI 通道）。
    func makeLoggedInClient(_ transport: StubTransport) -> GwmClient {
        let client = GwmClient(transport: transport)
        client.phone = "13800000000"
        client.deviceId = "0A1B2C3D4E5F60718293A4B5C6D7E8F9"
        client.gToken = "GTOKEN"
        client.gRefreshToken = "GREFRESH"
        client.ssoToken = "SSO"
        client.userId = "U123"
        client.beanId = "BEAN"
        client.btAccessToken = "BTACCESS"
        client.autoTokenId = "AUTOTOKEN"
        client.autoUserId = "AUTOUID"
        client.rememberPlatform("LSVAA1234567890", platform: "gtsp")
        return client
    }

    // MARK: - 状态查询

    func testGetStatusBuildsSignedGetRequest() async throws {
        let transport = StubTransport()
        transport.on(path: "/app-api/api/v3.0/vehicle/getLastStatus") { _ in
            json("{\"code\":\"0\",\"data\":{\"vehicleStatusInfo\":{\"esclLockSts\":\"1\",\"engineSts\":\"0\"}}}")
        }
        let client = makeLoggedInClient(transport)
        let status = try await client.getParsedStatus("lsvaa1234567890")

        let request = try XCTUnwrap(transport.lastRequest(path: "getLastStatus"))
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.url.hasSuffix("?vin=LSVAA1234567890"))
        XCTAssertEqual(request.headers["beanId"], "BEAN")
        XCTAssertEqual(request.headers["tokenId"], "AUTOTOKEN")
        XCTAssertEqual(request.headers["accessToken"], "BTACCESS")
        XCTAssertEqual(request.headers["bt-auth-appkey"], GwmCrypto.beanTechAppKey)
        XCTAssertEqual(request.headers["terminal"], "GW_APP_GWM")
        XCTAssertEqual(request.headers["appId"], "097a7099af30d960")
        XCTAssertEqual(request.headers["vin"], "LSVAA1234567890")
        XCTAssertEqual(request.headers["User-Agent"], GwmCrypto.officialUserAgent)
        XCTAssertNotNil(request.headers["bt-auth-sign"])
        XCTAssertNil(request.body)

        // 服务端签名的关键性质：可复算
        let nonce = try XCTUnwrap(request.headers["bt-auth-nonce"])
        let timestamp = try XCTUnwrap(request.headers["bt-auth-timestamp"])
        let expected = GwmCrypto.beanTechSign("GET", "/app-api/api/v3.0/vehicle/getLastStatus",
                                              nonce, timestamp, "vin=LSVAA1234567890")
        XCTAssertEqual(request.headers["bt-auth-sign"], expected)

        XCTAssertEqual(status.doorsLocked, false)
        XCTAssertEqual(status.engineState, "0")
    }

    func testAuthenticationFailureIsClassified() async {
        let transport = StubTransport()
        transport.on(path: "getLastStatus") { _ in json("{\"code\":\"401\"}", status: 401) }
        let client = makeLoggedInClient(transport)
        do {
            _ = try await client.getStatus("LSVAA1234567890")
            XCTFail("应当抛出认证错误")
        } catch let error as GwmError {
            guard case let .auth(message) = error else {
                return XCTFail("错误类型应为 auth，实际 \(error)")
            }
            XCTAssertTrue(message.contains("401"))
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    func testRiskControlCode1013() async {
        let transport = StubTransport()
        transport.on(path: "getLastStatus") { _ in json("{\"code\":\"1013\",\"msg\":\"need verify\"}") }
        let client = makeLoggedInClient(transport)
        do {
            _ = try await client.getStatus("LSVAA1234567890")
            XCTFail("应当抛出风控错误")
        } catch let error as GwmError {
            guard case .riskControl = error else { return XCTFail("应为 riskControl，实际 \(error)") }
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    /// 响应体是 G_A 信封时，客户端应自动解密。
    func testDecryptsEnvelopeResponse() async throws {
        let inner = "{\"vehicleStatusInfo\":{\"esclLockSts\":\"0\",\"engineSts\":\"2\"}}"
        let salt: [UInt8] = [7, 7, 7, 7, 1, 2, 3, 4]
        let envelope = try GwmCrypto.encryptEnvelope(inner, keyId: 1, salt: salt)
        let transport = StubTransport()
        transport.on(path: "getLastStatus") { _ in
            json("{\"code\":\"0\",\"data\":\"\(envelope)\"}")
        }
        let client = makeLoggedInClient(transport)
        let status = try await client.getParsedStatus("LSVAA1234567890")
        XCTAssertEqual(status.doorsLocked, true)
        XCTAssertEqual(status.engineState, "2")
    }

    // MARK: - 车辆列表

    func testGetVehiclesMapsPlatforms() async throws {
        let transport = StubTransport()
        transport.on(path: "query-vehicle-list") { _ in
            json("""
            {"code":"0","data":{"acquireVehiclesList":[
              {"vin":"lsvaa111","belongPlatform":"Gtsp","modelName":"哈弗H6","vehicleNick":"小黑","appShowSeriesName":"H6"},
              {"vin":"lsvaa222","belongPlatform":"BeanTech","modelName":"欧拉"}
            ]}}
            """)
        }
        let client = makeLoggedInClient(transport)
        let vehicles = try await client.getVehicles()

        XCTAssertEqual(vehicles.count, 2)
        XCTAssertEqual(vehicles[0].vin, "LSVAA111")
        XCTAssertEqual(vehicles[0].displayName(), "小黑")
        XCTAssertEqual(client.cachedPlatform("LSVAA111"), "gtsp")
        XCTAssertEqual(client.cachedPlatform("LSVAA222"), "beantech")
        XCTAssertEqual(vehicles[1].displayName(), "欧拉")

        let request = try XCTUnwrap(transport.lastRequest(path: "query-vehicle-list"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, "{\"vehicleVersion\":13}")
        XCTAssertEqual(request.headers["G-TOKEN"], "GTOKEN")
        XCTAssertEqual(request.headers["ssoId"], "U123")
        XCTAssertEqual(request.headers["SourceAppCode"], "2150")
        XCTAssertEqual(request.headers["AppId"], GwmCrypto.gAppAppId)
        XCTAssertNotNil(request.headers["Sign"])
    }

    // MARK: - 命令下发

    func testAutoAiCommandForGtsp() async throws {
        let transport = StubTransport()
        transport.on(path: "/tsp/ead") { _ in
            json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX-1\"}}")
        }
        let client = makeLoggedInClient(transport)
        let tx = try await client.sendCommand("LSVAA1234567890", GwmCommand.lock, nil)
        XCTAssertEqual(tx, "TX-1")

        let request = try XCTUnwrap(transport.lastRequest(path: "/tsp/ead"))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["token"], "AUTOTOKEN")
        XCTAssertEqual(request.headers["ckey"], GwmCrypto.autoAiCkey)
        XCTAssertEqual(request.headers["cid"], client.deviceId)
        // sign 是 time 的 HMAC-SHA1
        let time = try XCTUnwrap(request.headers["time"])
        XCTAssertEqual(request.headers["sign"], GwmCrypto.autoAiSign(time))

        // URL 里是 urlEncodeFull 过的 .NET JSON，解码后应包含 cmdCode=2（锁车）
        let encoded = try XCTUnwrap(request.url.components(separatedBy: "?p=").last)
        let decoded = encoded.removingPercentEncoding ?? ""
        XCTAssertTrue(decoded.contains("\"cmdCode\":2"), decoded)
        XCTAssertTrue(decoded.contains("\"vin\":\"LSVAA1234567890\""))
        XCTAssertTrue(decoded.contains("\"fn\":\"GW.M.SEND_COMMON_COMMAND\""))
        XCTAssertTrue(decoded.contains("\"signStr\":\""))
        XCTAssertTrue(decoded.contains("\"tk\":\"AUTOTOKEN\""))
    }

    /// 远程启动要带 engineParams.runTime，并按分钟数换算。
    func testEngineStartCarriesRunTime() async throws {
        let transport = StubTransport()
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX-2\"}}") }
        let client = makeLoggedInClient(transport)
        let body = VehicleAction.bodyOf(.engineStart, minutes: 20)
        _ = try await client.sendCommand("LSVAA1234567890", GwmCommand.engineStart, body)

        let request = try XCTUnwrap(transport.lastRequest(path: "/tsp/ead"))
        let decoded = (request.url.components(separatedBy: "?p=").last?.removingPercentEncoding) ?? ""
        XCTAssertTrue(decoded.contains("\"cmdCode\":15"), decoded)
        XCTAssertTrue(decoded.contains("\"engineParams\":{\"runTime\":20}"), decoded)
        XCTAssertTrue(decoded.contains("\"fn\":\"GW.M.SET_AND_OPEN_COMMAND\""), decoded)
    }

    /// 空调走 SET_AND_OPEN_COMMAND，并把秒换算成分钟。
    func testAcStartCarriesAirParams() async throws {
        let transport = StubTransport()
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX-3\"}}") }
        let client = makeLoggedInClient(transport)
        let body = TempControl.bodiesOf(24.5, zone: .both)
        _ = try await client.sendCommand("LSVAA1234567890", GwmCommand.acStart, body)

        let request = try XCTUnwrap(transport.lastRequest(path: "/tsp/ead"))
        let decoded = (request.url.components(separatedBy: "?p=").last?.removingPercentEncoding) ?? ""
        XCTAssertTrue(decoded.contains("\"cmdCode\":6"), decoded)
        XCTAssertTrue(decoded.contains("\"airParams\":{\"runTime\":10,\"temperature\":25}"), decoded)
        XCTAssertTrue(decoded.contains("\"fn\":\"GW.M.SET_AND_OPEN_COMMAND\""), decoded)
    }

    /// beantech 平台走 T5/sendCmd，且 timely 指令走另一个路径。
    func testBeanTechCommandPaths() async throws {
        let transport = StubTransport()
        transport.on(path: "T5/sendCmd") { _ in json("{\"code\":\"0\",\"data\":{}}") }
        transport.on(path: "remote-ctrl/timely") { _ in json("{\"code\":\"0\",\"data\":{}}") }
        let client = makeLoggedInClient(transport)
        client.rememberPlatform("LSVBB0000000001", platform: "beantech")
        XCTAssertFalse(client.isT5Unavailable("LSVBB0000000001"))

        let sequence = try await client.sendCommand("LSVBB0000000001", GwmCommand.lock, nil)
        XCTAssertFalse(sequence.isEmpty)

        let sendRequest = try XCTUnwrap(transport.lastRequest(path: "T5/sendCmd"))
        let body = try XCTUnwrap(sendRequest.body)
        XCTAssertTrue(body.contains("\"controlType\":\"VEHICLE_LOCK\""), body)
        XCTAssertTrue(body.contains("\"sendType\":0"))
        XCTAssertTrue(body.contains("\"seqNo\":\"\(sequence)\""))
        XCTAssertTrue(body.contains("\"isSaveConfig\":null"))
        XCTAssertTrue(body.contains("\"cmdBody\":null"))

        _ = try await client.sendCommand("LSVBB0000000001", GwmCommand.acStart, TempControl.bodiesOf(24, zone: .both))
        let timelyRequest = try XCTUnwrap(transport.lastRequest(path: "remote-ctrl/timely"))
        let timelyBody = try XCTUnwrap(timelyRequest.body)
        XCTAssertTrue(timelyBody.contains("\"controlType\":\"AIR_CONDITIONER_START\""), timelyBody)
        XCTAssertFalse(timelyBody.contains("isSaveConfig"), "timely 指令不应带 isSaveConfig")
        XCTAssertTrue(timelyBody.contains("\"cmdBody\":{"))
    }

    /// beantech 报 550002 时自动降级到 gtsp 并记住。
    func testBeanTech550002FallsBackToGtsp() async throws {
        let transport = StubTransport()
        transport.on(path: "T5/sendCmd") { _ in
            json("{\"code\":\"550002\",\"msg\":\"platform not support\"}")
        }
        transport.on(path: "/tsp/ead") { _ in json("{\"header\":{\"c\":\"0\"},\"body\":{\"transactionId\":\"TX-9\"}}") }
        let client = makeLoggedInClient(transport)
        client.rememberPlatform("LSVBB0000000002", platform: "beantech")

        let tx = try await client.sendCommand("LSVBB0000000002", GwmCommand.lock, nil)
        XCTAssertEqual(tx, "TX-9")
        XCTAssertEqual(client.cachedPlatform("LSVBB0000000002"), "gtsp")
    }

    /// 平台不支持该指令时应给出明确报错。
    func testUnsupportedCommandMessage() async {
        let transport = StubTransport()
        let client = makeLoggedInClient(transport)
        do {
            _ = try await client.sendCommand("LSVAA1234567890", "UNKNOWN_CMD", nil)
            XCTFail("应当失败")
        } catch let error as GwmError {
            guard case let .auth(message) = error else { return XCTFail("应为 auth") }
            XCTAssertTrue(message.contains("暂不支持该指令：UNKNOWN_CMD"), message)
            XCTAssertTrue(message.contains("gtsp 平台支持"))
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    /// -114 忙碌状态应被识别为可重试。
    func testBusyCodeIsRetryable() async {
        let transport = StubTransport()
        transport.on(path: "/tsp/ead") { _ in
            json("{\"header\":{\"c\":\"-114\",\"m\":\"running\"}}")
        }
        let client = makeLoggedInClient(transport)
        client.retryDelaysForTesting = [0, 0, 0, 0]
        do {
            _ = try await client.sendCommand("LSVAA1234567890", GwmCommand.lock, nil)
            XCTFail("应当失败")
        } catch let error as GwmError {
            guard case let .busy(message) = error else { return XCTFail("应为 busy，实际 \(error)") }
            XCTAssertTrue(message.contains("-114"), message)
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    // MARK: - 登录

    func testPasswordLoginSendsEncryptedBody() async throws {
        let transport = StubTransport()
        transport.on(path: "pwd-login") { _ in
            json("{\"code\":\"0\",\"data\":{\"gToken\":\"G1\",\"gRefreshToken\":\"R1\",\"userId\":\"U1\",\"ssoToken\":\"S1\",\"beanId\":\"B1\"}}")
        }
        transport.on(path: "loginSSOAccount") { _ in
            json("{\"code\":\"0\",\"data\":{\"accessToken\":\"BT1\",\"refreshToken\":\"BR1\",\"beanId\":\"B2\"}}")
        }
        transport.on(path: "GW.M.APP_LOGIN") { _ in
            json("{\"header\":{\"c\":\"0\"},\"body\":{\"tokenId\":\"AT1\",\"userId\":\"AU1\"}}")
        }
        transport.on(path: "query-vehicle-list") { _ in
            json("{\"code\":\"0\",\"data\":{\"acquireVehiclesList\":[{\"vin\":\"LSVCC1\",\"belongPlatform\":\"gtsp\"}]}}")
        }

        let client = GwmClient(transport: transport)
        client.deviceId = "DEVID"
        let vehicles = try await client.loginPassword("13800000000", "secret")

        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(client.gToken, "G1")
        XCTAssertEqual(client.btAccessToken, "BT1")
        XCTAssertEqual(client.btBeanId, "B2")
        XCTAssertEqual(client.autoTokenId, "AT1")
        XCTAssertTrue(client.isLoggedIn)

        let loginRequest = try XCTUnwrap(transport.lastRequest(path: "pwd-login"))
        let body = try XCTUnwrap(loginRequest.body)
        XCTAssertTrue(body.hasPrefix("G_A("), "登录请求体应加密")
        let plain = try XCTUnwrap(try GwmCrypto.decryptEnvelope(body))
        XCTAssertEqual(plain, "{\"phone\":\"13800000000\",\"deviceId\":\"DEVID\",\"password\":\"secret\",\"deviceToken\":\"\"}")
        XCTAssertEqual(loginRequest.headers["SourceType"], "ANDROID")
        XCTAssertEqual(loginRequest.headers["DeviceId"], "DEVID")
        XCTAssertNotNil(loginRequest.headers["Sign"])
    }

    /// 缺少 gRefreshToken 时应明确报 schema 错误，而不是继续登录。
    func testLoginRequiresRefreshToken() async {
        let transport = StubTransport()
        transport.on(path: "sms-login") { _ in
            json("{\"code\":\"0\",\"data\":{\"gToken\":\"G1\",\"userId\":\"U1\"}}")
        }
        let client = GwmClient(transport: transport)
        do {
            _ = try await client.loginSms("123456")
            XCTFail("应当失败")
        } catch let error as GwmError {
            guard case let .schema(message) = error else { return XCTFail("应为 schema") }
            XCTAssertTrue(message.contains("gToken/gRefreshToken/userId"), message)
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    func testStateMapRoundTrip() async throws {
        let transport = StubTransport()
        let client = makeLoggedInClient(transport)
        let state = client.toStateMap()
        let restored = GwmClient.fromStateMap(JSONParser.parse(GwmCrypto.encodeDotnetJSON(state)))
        XCTAssertEqual(restored.phone, client.phone)
        XCTAssertEqual(restored.deviceId, client.deviceId)
        XCTAssertEqual(restored.autoTokenId, "AUTOTOKEN")
        XCTAssertTrue(restored.isLoggedIn)
        XCTAssertEqual(restored.cachedPlatform("LSVAA1234567890"), "gtsp")
    }
}
