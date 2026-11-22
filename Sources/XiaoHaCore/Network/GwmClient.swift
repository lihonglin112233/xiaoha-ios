import Foundation

public enum GwmError: Error, LocalizedError {
    case auth(String)
    case busy(String)
    case connection(String)
    case riskControl(String)
    case schema(String)

    public var errorDescription: String? {
        switch self {
        case let .auth(message), let .busy(message), let .connection(message),
             let .riskControl(message), let .schema(message):
            return message
        }
    }

    /// GwmRepository.friendly 的等价文案。
    public var friendlyMessage: String {
        switch self {
        case let .riskControl(message):
            return message
        case let .auth(message):
            return message.contains("1013") ? "触发风控，请在官方 APP 完成验证后重试" : message
        case let .connection(message):
            return "网络异常：" + message
        case let .schema(message):
            return "数据异常：" + message
        case let .busy(message):
            return message
        }
    }
}

public enum GwmURLs {
    static let gAppBase = "https://gapp-api.gwmapp-h.com/"
    static let beanTechBase = "https://gw-app-gateway.gwmapp-h.com/"
    static let autoAiDirect = "https://ti.gwm.com.cn:8443/tsp/ead"
    static let autoAiLogin = "https://gapp-api.gwmapp-h.com/tsp/v1/proxy/navinfo/GW.M.APP_LOGIN"
    static let discovery = "https://gapp-api.gwmapp-h.com/gcar/v1/app/android/vehicle/query-vehicle-list"
    static let pwdLogin = "https://gapp-api.gwmapp-h.com/api-guser/v5/user/pwd-login"
    static let smsLogin = "https://gapp-api.gwmapp-h.com/api-guser/v5/user/sms-login"
    static let smsSend = "https://gapp-api.gwmapp-h.com/api-guser/v5/user/login-sms/send"
    static let refresh = "https://gapp-api.gwmapp-h.com/api-guser/v5/token/refresh"

    static let btLoginPath = "/app-api/api/v1.0/userAuth/loginSSOAccount"
    static let btSendPath = "/app-api/api/v1.0/vehicle/T5/sendCmd"
    static let btResultPath = "/app-api/api/v1.0/vehicle/getRemoteCtrlResultT5"
    static let btStatusPath = "/app-api/api/v3.0/vehicle/getLastStatus"
    static let btTimelyPath = "/app-api/api/v3.0/vehicle/remote-ctrl/timely"

    static func beanTech(_ path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return beanTechBase + trimmed
    }
}

/// 车云客户端，逻辑对齐原 APK 的 GwmClient。
public final class GwmClient: @unchecked Sendable {
    public var phone = ""
    public var deviceId = GwmCrypto.randomDeviceId()
    public var gToken: String?
    public var gRefreshToken: String?
    public var ssoToken: String?
    public var ptToken: String?
    public var userId: String?
    public var beanId: String?
    public var btAccessToken: String?
    public var btRefreshToken: String?
    public var btBeanId: String?
    public var autoTokenId: String?
    public var autoUserId: String?

    private var platformCache: [String: String] = [:]
    private var t5BrokenVins: Set<String> = []
    private var timeoutSeconds: TimeInterval = 20
    private let transport: HTTPTransport
    private let lock = NSRecursiveLock()

    public init(transport: HTTPTransport = URLSessionTransport(),
                busyRetryDelays: [TimeInterval] = [12, 15, 15, 15]) {
        self.transport = transport
        self.busyRetryDelays = busyRetryDelays
    }

    public func setTimeoutSeconds(_ seconds: Int) {
        timeoutSeconds = TimeInterval(max(5, seconds))
    }

    // MARK: - 会话状态

    public var hasGApp: Bool {
        notEmpty(gToken) && notEmpty(gRefreshToken) && notEmpty(userId)
    }

    public var hasRefreshableSession: Bool { hasGApp }

    public var isLoggedIn: Bool {
        hasGApp && notEmpty(beanId) && notEmpty(btAccessToken)
            && notEmpty(autoTokenId) && notEmpty(autoUserId)
    }

    public func cachedPlatform(_ vin: String?) -> String {
        lock.lock(); defer { lock.unlock() }
        return platformCache[(vin ?? "").trimmed.uppercased()] ?? ""
    }

    /// 记录 VIN 所属平台。注意：不能顺手把 VIN 标记为 t5 不可用，
    /// 否则 beantech 车辆会被误判为必须走 gtsp。
    public func rememberPlatform(_ vin: String, platform: String) {
        lock.lock(); defer { lock.unlock() }
        platformCache[vin.trimmed.uppercased()] = platform.lowercased()
    }

    /// 显式把 VIN 记为 T5 通道不可用（等价原来 t5Broken 集合）。
    public func markT5Unavailable(_ vin: String) {
        markT5Broken(vin.trimmed.uppercased())
    }

    public func isT5Unavailable(_ vin: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return t5BrokenVins.contains(vin.trimmed.uppercased())
    }

    /// 同步更新平台缓存，避免在 async 上下文里直接持有 NSLock。
    private func markT5Broken(_ vin: String) {
        lock.lock(); defer { lock.unlock() }
        t5BrokenVins.insert(vin)
        platformCache[vin] = "gtsp"
    }

    /// 当前平台，供上层按平台给出能力提示。
    public func currentPlatform(_ vin: String) -> String {
        cachedPlatform(vin)
    }

    private func setPlatform(_ vin: String, _ platform: String) {
        lock.lock(); defer { lock.unlock() }
        platformCache[vin] = platform
    }

    /// 忙碌重试的等待时间，可注入以便测试不等真实时间。
    private var busyRetryDelays: [TimeInterval] = [12, 15, 15, 15]

    /// 仅供测试：把重试等待压缩为 0。
    public var retryDelaysForTesting: [TimeInterval]? {
        get { busyRetryDelays }
        set { busyRetryDelays = newValue ?? [12, 15, 15, 15] }
    }

    // MARK: - 状态序列化

    public func toStateMap() -> JSONValue {
        var pairs: [(String, JSONValue)] = []
        pairs.append(("phone", .string(phone)))
        pairs.append(("device_id", .string(deviceId)))
        pairs.append(("g_token", .optionalString(gToken)))
        pairs.append(("g_refresh_token", .optionalString(gRefreshToken)))
        pairs.append(("sso_token", .optionalString(ssoToken)))
        pairs.append(("pt_token", .optionalString(ptToken)))
        pairs.append(("user_id", .optionalString(userId)))
        pairs.append(("bean_id", .optionalString(beanId)))
        pairs.append(("bt_access_token", .optionalString(btAccessToken)))
        pairs.append(("bt_refresh_token", .optionalString(btRefreshToken)))
        pairs.append(("bt_bean_id", .optionalString(btBeanId)))
        pairs.append(("auto_token_id", .optionalString(autoTokenId)))
        pairs.append(("auto_user_id", .optionalString(autoUserId)))
        let platforms = platformCache.keys.sorted().map { "\($0)=\(platformCache[$0] ?? "")" }.joined(separator: ";")
        pairs.append(("platforms", .string(platforms)))
        pairs.append(("t5broken", .string(t5BrokenVins.sorted().joined(separator: ";"))))
        return .object(pairs)
    }

    public static func fromStateMap(_ value: JSONValue?) -> GwmClient {
        let client = GwmClient()
        guard let value, value.asObject != nil else { return client }
        client.phone = value.value("phone")?.asString ?? ""
        let storedDevice = value.value("device_id")?.asString ?? ""
        client.deviceId = storedDevice.isEmpty ? GwmCrypto.randomDeviceId() : storedDevice
        client.gToken = nonEmptyString(value.value("g_token"))
        client.gRefreshToken = nonEmptyString(value.value("g_refresh_token"))
        client.ssoToken = nonEmptyString(value.value("sso_token"))
        client.ptToken = nonEmptyString(value.value("pt_token"))
        client.userId = nonEmptyString(value.value("user_id"))
        client.beanId = nonEmptyString(value.value("bean_id"))
        client.btAccessToken = nonEmptyString(value.value("bt_access_token"))
        client.btRefreshToken = nonEmptyString(value.value("bt_refresh_token"))
        client.btBeanId = nonEmptyString(value.value("bt_bean_id"))
        client.autoTokenId = nonEmptyString(value.value("auto_token_id"))
        client.autoUserId = nonEmptyString(value.value("auto_user_id"))
        for entry in (value.value("platforms")?.asString ?? "").split(separator: ";") {
            let text = String(entry)
            if let eq = text.firstIndex(of: "=") {
                let key = String(text[text.startIndex..<eq])
                let val = String(text[text.index(after: eq)...])
                if !key.isEmpty { client.platformCache[key] = val }
            }
        }
        for entry in (value.value("t5broken")?.asString ?? "").split(separator: ";") where !entry.isEmpty {
            client.t5BrokenVins.insert(String(entry))
            client.platformCache[String(entry)] = "gtsp"
        }
        return client
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let text = value?.asString, !text.isEmpty, text != "null" else { return nil }
        return text
    }

    // MARK: - HTTP

    struct HttpResult {
        let code: Int
        let body: String
    }

    private func http(_ method: String, _ url: String, headers: [String: String], body: String?) async throws -> HttpResult {
        let request = HTTPRequest(method: method, url: url, headers: headers, body: body, timeout: timeoutSeconds)
        do {
            let response = try await transport.send(request)
            return HttpResult(code: response.statusCode, body: response.body)
        } catch let error as GwmError {
            throw error
        } catch {
            throw GwmError.connection(error.localizedDescription)
        }
    }

    private func checkHTTP(_ result: HttpResult, _ scope: String) throws {
        if result.code == 401 || result.code == 403 {
            throw GwmError.auth("\(scope): 认证失败（HTTP \(result.code)）")
        }
        if result.code < 200 || result.code > 299 {
            throw GwmError.connection("\(scope): HTTP \(result.code)")
        }
    }

    // MARK: - 响应解析

    private func decodeAutoAiResponse(_ result: HttpResult, _ scope: String) throws -> JSONValue {
        try checkHTTP(result, scope)
        let parsed = JSONParser.parse(result.body) ?? .null
        guard parsed.asObject != nil, parsed.valueIgnoringCase("header") != nil else {
            return try decodeGAppResponse(result, scope)
        }
        let header = parsed.valueIgnoringCase("header")
        let codeText = header?.stringIgnoringCase("c")
        if codeText == nil || codeText!.isEmpty || codeText == "0" {
            let body = parsed.valueIgnoringCase("body")
            return body ?? parsed
        }
        if codeText == "1013" {
            throw GwmError.riskControl("触发风控（1013），请在官方 APP 完成验证后再试")
        }
        let message = header?.stringIgnoringCase("m") ?? ""
        if codeText == "-114" {
            throw GwmError.busy("\(scope): 上一条远控还在执行中（-114 \(message)）。车端执行一条远控通常需要 10~30 秒，正在自动等待重试…")
        }
        throw GwmError.auth("\(scope): AutoAI 返回错误码 \(codeText ?? "") \(message)".trimmingCharacters(in: .whitespaces))
    }

    private func decodeGAppResponse(_ result: HttpResult, _ scope: String) throws -> JSONValue {
        try checkHTTP(result, scope)
        guard var payload = JSONParser.parse(result.body), payload.asObject != nil else {
            throw GwmError.schema("\(scope): 响应不是 JSON 对象")
        }
        let codeText = payload.stringIgnoringCase("code")
        if let codeText, !codeText.isEmpty, codeText != "0", codeText != "000000", codeText != "200" {
            if codeText == "1013" {
                throw GwmError.riskControl("触发风控（1013），请在官方 APP 完成验证后再试")
            }
            var description = payload.stringIgnoringCase("description")
            if description == nil { description = payload.stringIgnoringCase("msg") }
            if description == nil || description!.isEmpty {
                description = "响应: " + Self.summarizeBody(result.body)
            }
            throw GwmError.auth("\(scope): API 返回错误码 \(codeText) \(description ?? "")".trimmingCharacters(in: .whitespaces))
        }
        if let data = payload.valueIgnoringCase("data") { payload = data }
        guard case let .string(text) = payload, text.hasPrefix("G_A(") else { return payload }
        do {
            let plain = try GwmCrypto.decryptEnvelope(text)
            return JSONParser.parse(plain) ?? .null
        } catch {
            throw GwmError.schema("\(scope): G_A 信封解密失败")
        }
    }

    static func summarizeBody(_ body: String?) -> String {
        guard let body else { return "(空)" }
        let compact = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return compact.count > 160 ? String(compact.prefix(160)) + "…" : compact
    }

    private func applyGAppData(_ map: JSONValue?) throws {
        guard let map, map.asObject != nil else { throw GwmError.schema("G-App 响应格式异常") }
        let token = map.valueIgnoringCase("gToken") ?? map.valueIgnoringCase("token")
        let refreshToken = map.valueIgnoringCase("gRefreshToken") ?? map.valueIgnoringCase("refreshToken")
        let sso = map.valueIgnoringCase("ssoToken")
        let pt = map.valueIgnoringCase("ptToken")
        let uid = map.valueIgnoringCase("userId")
        let bean = map.valueIgnoringCase("beanId")
        if let token, let refreshToken, let uid {
            gToken = token.asString
            gRefreshToken = refreshToken.asString
            userId = uid.asString
        }
        if let sso { ssoToken = sso.asString }
        if let pt { ptToken = pt.asString }
        if let bean { beanId = bean.asString }
        if !hasGApp {
            throw GwmError.schema("G-App 登录响应缺少必需字段（gToken/gRefreshToken/userId）")
        }
    }

    // MARK: - G-App 通道

    private func gAppPost(_ scope: String, _ url: String, _ body: JSONValue, encrypt: Bool) async throws -> JSONValue {
        var payload = GwmCrypto.encodeDotnetJSON(body)
        if encrypt {
            payload = try GwmCrypto.encryptEnvelope(payload, keyId: 1)
        }
        let timestamp = String(Int64(Date().timeIntervalSince1970) * 1000)
        var signHeaders: [String: String] = [:]
        signHeaders["Authorization"] = btAccessToken ?? ""
        signHeaders["SourceApp"] = "GWM"
        signHeaders["SourceType"] = "ANDROID"
        signHeaders["SourceAppVer"] = GwmCrypto.sourceAppVersion
        signHeaders["Timestamp"] = timestamp
        signHeaders["DeviceId"] = deviceId
        signHeaders["AppId"] = GwmCrypto.gAppAppId
        signHeaders["NoteId"] = GwmCrypto.defaultNoteId

        var headers: [String: String] = [:]
        if let gToken { headers["G-TOKEN"] = gToken }
        headers["Authorization"] = btAccessToken ?? ""
        if let userId { headers["ssoId"] = userId }
        headers["SourceApp"] = "GWM"
        headers["SourceType"] = "ANDROID"
        headers["SourceAppVer"] = GwmCrypto.sourceAppVersion
        headers["SourceAppCode"] = GwmCrypto.sourceAppCode
        headers["Timestamp"] = timestamp
        headers["DeviceId"] = deviceId
        headers["AppId"] = GwmCrypto.gAppAppId
        if let beanId { headers["beanId"] = beanId }
        headers["NoteId"] = GwmCrypto.defaultNoteId
        headers["Sign"] = GwmCrypto.defaultSign("POST", url, payload, signHeaders)
        headers["Accept-Encoding"] = "gzip"
        headers["User-Agent"] = GwmCrypto.officialUserAgent
        headers["Content-Type"] = "application/json; charset=UTF-8"

        let result = try await http("POST", url, headers: headers, body: payload)
        return try decodeGAppResponse(result, scope)
    }

    // MARK: - 双通道初始化

    private func initializeServices() async throws {
        guard ssoToken != nil || ptToken != nil else {
            throw GwmError.schema("缺少 ssoToken，无法登录 BeanTech")
        }
        var beanLoginBody: [(String, JSONValue)] = []
        beanLoginBody.append(("appType", .int(0)))
        beanLoginBody.append(("deviceId", .string(deviceId)))
        beanLoginBody.append(("phone", .string(phone)))
        beanLoginBody.append(("ssoId", .optionalString(userId)))
        beanLoginBody.append(("ssoToken", .string(ssoToken ?? ptToken ?? "")))
        let beanBody = GwmCrypto.encodeDotnetJSON(.object(beanLoginBody))
        let beanTime = String(Int64(Date().timeIntervalSince1970 * 1000))
        let beanNonce = GwmCrypto.randomNonce()
        var beanHeaders = beanTechBaseHeaders(beanNonce, beanTime)
        beanHeaders["bt-auth-sign"] = GwmCrypto.beanTechSign("POST", GwmURLs.btLoginPath, beanNonce, beanTime, "json=" + beanBody)
        if let beanId { beanHeaders["beanId"] = beanId }
        beanHeaders["Content-Type"] = "application/json; charset=UTF-8"

        let beanResult = try await http("POST", GwmURLs.beanTech(GwmURLs.btLoginPath), headers: beanHeaders, body: beanBody)
        let beanData = try decodeGAppResponse(beanResult, "initialize_bean_tech")
        guard beanData.asObject != nil else { throw GwmError.schema("BeanTech 登录响应格式异常") }
        guard let accessToken = beanData.valueIgnoringCase("accessToken") else {
            throw GwmError.schema("BeanTech 登录响应缺少 accessToken")
        }
        btAccessToken = accessToken.asString
        if let refresh = beanData.valueIgnoringCase("refreshToken") { btRefreshToken = refresh.asString }
        btBeanId = beanData.valueIgnoringCase("beanId")?.asString ?? beanId

        guard let ssoToken else { throw GwmError.schema("缺少 ssoToken，无法登录 AutoAI") }
        var autoBody: [(String, JSONValue)] = []
        autoBody.append(("appType", .int(0)))
        autoBody.append(("phone", .string(phone)))
        autoBody.append(("pushId", .string("0")))
        autoBody.append(("pushKey", .string("0")))
        autoBody.append(("ssoid", .optionalString(userId)))
        autoBody.append(("ssoTk", .string(ssoToken)))
        let autoHeaderTime = GwmCrypto.chinaTimestamp()
        var autoHeader: [(String, JSONValue)] = []
        autoHeader.append(("brandType", .string("gwm")))
        autoHeader.append(("cVer", .string(GwmCrypto.sourceAppVersion)))
        autoHeader.append(("fn", .string("GW.M.APP_LOGIN")))
        autoHeader.append(("fv", .string("0202")))
        autoHeader.append(("mobileId", .string(deviceId)))
        autoHeader.append(("osType", .string("Android")))
        autoHeader.append(("osVer", .string("")))
        autoHeader.append(("rs", .string("2")))
        autoHeader.append(("ts", .string(autoHeaderTime)))
        autoHeader.append(("tk", .string("")))
        autoHeader.append(("v", .string("1.0")))

        let envelope = GwmCrypto.encodeDotnetJSON(.object([("body", .object(autoBody)), ("header", .object(autoHeader))]))
        let loginURL = GwmURLs.autoAiLogin + "?p=" + JavaURL.encodeFull(envelope)
        let time = String(Int64(Date().timeIntervalSince1970 * 1000))
        var autoHeaders: [String: String] = [:]
        autoHeaders["v"] = "1.0"
        autoHeaders["cid"] = deviceId
        autoHeaders["client"] = "phone"
        autoHeaders["sign"] = GwmCrypto.autoAiSign(time)
        autoHeaders["time"] = time
        autoHeaders["ckey"] = GwmCrypto.autoAiCkey
        autoHeaders["protocolVer"] = "2.1.2"
        autoHeaders["brandType"] = "GWM"
        autoHeaders["Accept-Encoding"] = "gzip"
        autoHeaders["User-Agent"] = GwmCrypto.officialUserAgent

        let autoLoginResult = try await http("GET", loginURL, headers: autoHeaders, body: nil)
        let autoData = try decodeAutoAiResponse(autoLoginResult, "initialize_auto_ai")
        guard let tokenId = autoData.valueIgnoringCase("tokenId"),
              let autoUid = autoData.valueIgnoringCase("userId") else {
            throw GwmError.schema("AutoAI 登录响应缺少 tokenId/userId")
        }
        autoTokenId = tokenId.asString
        autoUserId = autoUid.asString
    }

    private func beanTechBaseHeaders(_ nonce: String, _ timestamp: String) -> [String: String] {
        [
            "securityToken": "",
            "tenantId": "1",
            "terminal": "GW_APP_GWM",
            "enterPriseId": "CC01",
            "operatorRole": "0",
            "rs": "2",
            "sys": "app-android",
            "cVer": GwmCrypto.sourceAppVersion,
            "appId": "097a7099af30d960",
            "brand": "10",
            "bt-auth-appkey": GwmCrypto.beanTechAppKey,
            "bt-auth-nonce": nonce,
            "bt-auth-timestamp": timestamp,
            "Accept-Encoding": "gzip",
            "User-Agent": GwmCrypto.officialUserAgent,
        ]
    }

    private func beanTechHeaders(_ method: String, _ path: String, _ nonce: String, _ timestamp: String,
                                 _ extra: String, _ vin: String) throws -> [String: String] {
        let effectiveBeanId = btBeanId ?? beanId
        guard notEmpty(btAccessToken), notEmpty(effectiveBeanId), notEmpty(autoTokenId) else {
            throw GwmError.auth("BeanTech 会话不完整，请重新登录")
        }
        return [
            "securityToken": "",
            "beanId": effectiveBeanId!,
            "tenantId": "1",
            "terminal": "GW_APP_GWM",
            "tokenId": autoTokenId!,
            "accessToken": btAccessToken!,
            "enterPriseId": "CC01",
            "operatorRole": "0",
            "rs": "2",
            "sys": "app-android",
            "vin": vin,
            "cVer": GwmCrypto.sourceAppVersion,
            "appId": "097a7099af30d960",
            "brand": "10",
            "bt-auth-sign": GwmCrypto.beanTechSign(method, path, nonce, timestamp, extra),
            "bt-auth-nonce": nonce,
            "bt-auth-appkey": GwmCrypto.beanTechAppKey,
            "bt-auth-timestamp": timestamp,
            "Content-Type": "application/json; charset=UTF-8",
            "Connection": "Keep-Alive",
            "Accept-Encoding": "gzip",
            "User-Agent": GwmCrypto.officialUserAgent,
        ]
    }

    // MARK: - 命令下发

    private func sendAutoAiCommand(_ vin: String, code: Int, function: String, extra: JSONValue?) async throws -> String {
        let time = String(Int64(Date().timeIntervalSince1970 * 1000))
        var body: [(String, JSONValue)] = []
        body.append(("flag", .int(1)))
        body.append(("signStr", .string(GwmCrypto.md5Hex(vin + (autoTokenId ?? "")))))
        body.append(("userId", .optionalString(autoUserId)))
        body.append(("userType", .string("0")))
        body.append(("vin", .string(vin)))
        body.append(("cmdCode", .int(code)))
        if let extra, let pairs = extra.asObject {
            body.append(contentsOf: pairs)
        }
        var header: [(String, JSONValue)] = []
        header.append(("brandType", .string("gwm")))
        header.append(("cVer", .string(GwmCrypto.sourceAppVersion)))
        header.append(("fn", .string(function)))
        header.append(("fv", .string("0202")))
        header.append(("mobileId", .string(deviceId)))
        header.append(("osType", .string("Android")))
        header.append(("osVer", .string("")))
        header.append(("rs", .string("2")))
        header.append(("ts", .string(GwmCrypto.chinaTimestamp())))
        header.append(("tk", .optionalString(autoTokenId)))
        header.append(("v", .string("1.0")))

        let payload = GwmCrypto.encodeDotnetJSON(.object([("body", .object(body)), ("header", .object(header))]))
        let url = GwmURLs.autoAiDirect + "?p=" + JavaURL.encodeFull(payload)
        var headers: [String: String] = [:]
        headers["v"] = "1.0"
        headers["cid"] = deviceId
        headers["client"] = "phone"
        headers["sign"] = GwmCrypto.autoAiSign(time)
        headers["time"] = time
        headers["ckey"] = GwmCrypto.autoAiCkey
        headers["token"] = autoTokenId ?? ""
        headers["protocolVer"] = "2.1.2"
        headers["brandType"] = "GWM"
        headers["Accept-Encoding"] = "gzip"
        headers["User-Agent"] = GwmCrypto.officialUserAgent

        let result = try await http("GET", url, headers: headers, body: nil)
        let data = try decodeAutoAiResponse(result, "send_cmd")
        guard let transactionId = data.valueIgnoringCase("transactionId") else {
            throw GwmError.schema("AutoAI 远控响应缺少 transactionId")
        }
        return transactionId.asString ?? ""
    }

    private func sendBeanTechCommand(_ vin: String, _ controlType: String, _ body: JSONValue?) async throws -> String {
        let sequence = GwmCrypto.randomSequence()
        let isTimely = GwmCommand.timelyCommands.contains(controlType)
        let includeBody = !isTimely || GwmCommand.timelyWithBody.contains(controlType)

        var command: [(String, JSONValue)] = []
        if includeBody {
            command.append(("cmdBody", body ?? .null))
        }
        command.append(("controlType", .string(controlType)))

        var request: [(String, JSONValue)] = []
        request.append(("commands", .array([.object(command)])))
        request.append(("sendType", .int(0)))
        request.append(("seqNo", .string(sequence)))
        request.append(("vin", .string(vin)))
        if !isTimely {
            request.append(("isSaveConfig", .null))
        }
        let payload = GwmCrypto.encodeDotnetJSON(.object(request))
        let path = isTimely ? GwmURLs.btTimelyPath : GwmURLs.btSendPath
        let headers = try beanTechHeaders("POST", path, GwmCrypto.randomNonce(),
                                         String(Int64(Date().timeIntervalSince1970 * 1000)),
                                         "json=" + payload, vin)
        let result = try await http("POST", GwmURLs.beanTech(path), headers: headers, body: payload)
        _ = try decodeGAppResponse(result, "send_cmd")
        return sequence
    }

    private func sendCommandInner(_ vin: String, _ controlType: String, _ body: JSONValue?) async throws -> String {
        let upper = vin.trimmingCharacters(in: .whitespaces).uppercased()
        guard isLoggedIn else { throw GwmError.auth("未完成登录") }
        var platform = (try? await getPlatform(upper)) ?? ""

        if platform == "beantech" && !t5BrokenVins.contains(upper) {
            do {
                return try await sendBeanTechCommand(upper, controlType, body)
            } catch let error as GwmError {
                guard case let .auth(message) = error, message.contains("550002") else { throw error }
                markT5Broken(upper)
                platform = "gtsp"
            }
        }

        var code = GwmCommand.autoAiCodes[controlType]
        if controlType == GwmCommand.acStart {
            code = 6
        } else if controlType == GwmCommand.acStop {
            code = 7
        }
        guard let code else {
            let platformText = platform.isEmpty ? "未知" : platform
            throw GwmError.auth("平台 \(platformText) 暂不支持该指令：\(controlType)（gtsp 平台支持 锁车/解锁/关全车窗/鸣笛/闪灯/鸣笛闪灯/空调开/空调关/远程启动/熄火/关天窗）")
        }

        let function = (controlType == GwmCommand.engineStart || controlType == GwmCommand.acStart)
            ? "GW.M.SET_AND_OPEN_COMMAND"
            : "GW.M.SEND_COMMON_COMMAND"

        var extra: JSONValue?
        if controlType == GwmCommand.engineStart {
            let seconds = body?.value("operationTime")?.asDouble ?? 900
            let minutes = max(1, Int(seconds) / 60)
            extra = .object([("engineParams", .object([("runTime", .int(minutes))]))])
        } else if controlType == GwmCommand.acStart {
            let operationTime = body?.value("operationTime")?.asDouble ?? Double(TempControl.defaultDurationSeconds)
            var airParams: [(String, JSONValue)] = []
            airParams.append(("runTime", .int(max(1, Int(operationTime) / 60))))
            if let temperature = body?.value("temperature")?.asDouble {
                airParams.append(("temperature", .int(Int(temperature))))
            }
            extra = .object([("airParams", .object(airParams))])
        }
        return try await sendAutoAiCommand(upper, code: code, function: function, extra: extra)
    }

    /// 带会话恢复与忙碌重试的下发入口。
    public func sendCommand(_ vin: String, _ controlType: String, _ body: JSONValue?) async throws -> String {
        var busyAttempts = 0
        while true {
            do {
                return try await sendCommandInner(vin, controlType, body)
            } catch let error as GwmError {
                if case let .auth(message) = error {
                    if !message.contains("会话") && !message.contains("-101") && !message.contains("认证失败") {
                        throw error
                    }
                    try await recoverSession()
                    return try await sendCommandInner(vin, controlType, body)
                }
                if case let .busy(message) = error {
                    busyAttempts += 1
                    guard busyAttempts <= busyRetryDelays.count else { throw GwmError.busy(message) }
                    let seconds = busyRetryDelays[busyAttempts - 1]
                    if seconds > 0 {
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    }
                    continue
                }
                throw error
            }
        }
    }

    // MARK: - 查询

    public func getCommandResult(_ vin: String, _ sequence: String) async throws -> JSONValue? {
        let upper = vin.trimmingCharacters(in: .whitespaces).uppercased()
        guard isLoggedIn else { throw GwmError.auth("未完成登录") }
        let headers = try beanTechHeaders("GET", GwmURLs.btResultPath, GwmCrypto.randomNonce(),
                                          String(Int64(Date().timeIntervalSince1970 * 1000)),
                                          "seqno=" + sequence, upper)
        let url = GwmURLs.beanTech(GwmURLs.btResultPath) + "?seqNo=" + JavaURL.encodeSpacesAsPercent(sequence)
        let result = try await http("GET", url, headers: headers, body: nil)
        let decoded = try decodeGAppResponse(result, "get_cmd_result")
        return decoded.asObject != nil ? decoded : nil
    }

    public func getStatus(_ vin: String) async throws -> JSONValue {
        let upper = vin.trimmingCharacters(in: .whitespaces).uppercased()
        guard isLoggedIn else { throw GwmError.auth("未完成登录") }
        let headers = try beanTechHeaders("GET", GwmURLs.btStatusPath, GwmCrypto.randomNonce(),
                                          String(Int64(Date().timeIntervalSince1970 * 1000)),
                                          "vin=" + upper, upper)
        let url = GwmURLs.beanTech(GwmURLs.btStatusPath) + "?vin=" + JavaURL.encodeSpacesAsPercent(upper)
        let result = try await http("GET", url, headers: headers, body: nil)
        let decoded = try decodeGAppResponse(result, "get_last_status")
        return decoded.asObject != nil ? decoded : .object([])
    }

    public func getParsedStatus(_ vin: String) async throws -> VehicleStatus {
        VehicleStatus.parse(try await getStatus(vin))
    }

    public func getPlatform(_ vin: String) async throws -> String {
        let upper = vin.trimmingCharacters(in: .whitespaces).uppercased()
        if platformCache[upper] == nil {
            _ = try await getVehicles()
        }
        return platformCache[upper] ?? ""
    }

    public func getVehicles() async throws -> [GwmVehicle] {
        var result = try await gAppPost("acquire_vehicles", GwmURLs.discovery,
                                        .object([("vehicleVersion", .int(13))]), encrypt: false)
        if let list = result.valueIgnoringCase("acquireVehiclesList") { result = list }
        guard let items = result.asArray else { throw GwmError.schema("车辆列表格式异常") }
        var vehicles: [GwmVehicle] = []
        for item in items {
            guard let vinValue = item.valueIgnoringCase("vin"),
                  let rawVin = vinValue.asString, !rawVin.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let vin = rawVin.trimmingCharacters(in: .whitespaces).uppercased()
            var vehicle = GwmVehicle(vin: vin)
            vehicle.modelName = item.stringIgnoringCase("modelName")
            vehicle.seriesName = item.stringIgnoringCase("appShowSeriesName")
            vehicle.nickname = item.stringIgnoringCase("vehicleNick")
            vehicle.brandName = item.stringIgnoringCase("brandName")
            let platform = item.stringIgnoringCase("belongPlatform")?.trimmingCharacters(in: .whitespaces) ?? ""
            vehicle.platform = platform
            vehicles.append(vehicle)
            setPlatform(vin, t5BrokenVins.contains(vin) ? "gtsp" : platform.lowercased())
        }
        return vehicles
    }

    // MARK: - 登录

    public func requestSmsCode(_ phone: String) async throws {
        self.phone = phone.trimmingCharacters(in: .whitespaces)
        let body = JSONValue.object([("phone", .string(self.phone)), ("flag", .string("LOGIN"))])
        _ = try await gAppPost("request_verification", GwmURLs.smsSend, body, encrypt: true)
    }

    public func loginPassword(_ phone: String, _ password: String) async throws -> [GwmVehicle] {
        self.phone = phone.trimmingCharacters(in: .whitespaces)
        guard !self.phone.isEmpty else { throw GwmError.auth("手机号不能为空") }
        guard !password.isEmpty else { throw GwmError.auth("密码不能为空") }
        let body = JSONValue.object([
            ("phone", .string(self.phone)),
            ("deviceId", .string(deviceId)),
            ("password", .string(password)),
            ("deviceToken", .string("")),
        ])
        let data = try await gAppPost("login_pwd", GwmURLs.pwdLogin, body, encrypt: true)
        try applyGAppData(data)
        try await initializeServices()
        return try await getVehicles()
    }

    public func loginSms(_ code: String) async throws -> [GwmVehicle] {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw GwmError.auth("验证码不能为空") }
        let body = JSONValue.object([
            ("code", .string(trimmed)),
            ("phone", .string(phone)),
            ("deviceToken", .string("")),
        ])
        let data = try await gAppPost("login", GwmURLs.smsLogin, body, encrypt: true)
        try applyGAppData(data)
        try await initializeServices()
        return try await getVehicles()
    }

    /// 用刷新令牌换取新会话，然后重建两条通道。
    public func refresh() async throws {
        guard hasGApp else { throw GwmError.auth("没有可刷新的登录状态，请重新短信登录") }
        let body = JSONValue.object([
            ("token", .optionalString(gToken)),
            ("refreshToken", .optionalString(gRefreshToken)),
        ])
        let data = try await gAppPost("refresh_token", GwmURLs.refresh, body, encrypt: true)
        try applyGAppData(data)
        try await initializeServices()
    }

    public func recoverSession() async throws {
        do {
            try await initializeServices()
        } catch let error as GwmError {
            switch error {
            case .auth, .schema:
                try await refresh()
            default:
                throw error
            }
        }
    }

    /// 静默恢复：先刷新令牌，再尝试重建通道。
    public func reviveSessionQuietly() async -> Bool {
        guard hasGApp else { return false }
        if isLoggedIn { return true }
        try? await refresh()
        try? await initializeServices()
        return isLoggedIn
    }

    private func notEmpty(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.isEmpty
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
