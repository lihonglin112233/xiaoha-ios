import Foundation

/// 会话持久化，对齐原 APK 的 SessionCodec + GwmSecureStore。
public struct SessionCodec {
    public static let formatVersion = 2
    private(set) public var lastError: String?

    public init() {}

    public static func sha1Hex(_ text: String) -> String {
        Hex.encodeLower(Digest.sha1(Array(text.utf8)))
    }

    public static func wrap(_ payload: String) -> String {
        "{\"v\":2,\"sha\":\"" + sha1Hex(payload) + "\",\"data\":" + payload + "}"
    }

    /// 与原实现的三类错误文案保持一致：
    /// 顶层不是对象 → 格式异常；解析抛错 → 已失效；缺刷新令牌 → 缺少刷新令牌。
    public mutating func decode(_ text: String?) -> GwmClient? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastError = nil
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = JSONParser.parseStrict(trimmed) else {
            // 原实现里 JsonLite 抛 IllegalArgumentException，被兜底成"已失效"
            lastError = "登录凭据已失效（IllegalArgumentException），需要重新登录"
            return nil
        }
        guard parsed.asObject != nil else {
            lastError = "登录凭据格式异常，需要重新登录"
            return nil
        }
        var payloadText = trimmed
        if let dataValue = parsed.value("data"), dataValue.asObject != nil {
            payloadText = GwmCrypto.encodeDotnetJSON(dataValue)
        }
        guard let state = JSONParser.parseStrict(payloadText), state.asObject != nil else {
            lastError = "登录凭据格式异常，需要重新登录"
            return nil
        }
        let client = GwmClient.fromStateMap(state)
        guard client.hasRefreshableSession else {
            lastError = "本地凭据缺少刷新令牌，需要重新登录"
            return nil
        }
        lastError = nil
        return client
    }

    public mutating func decodeFirst(_ candidates: [String?]) -> GwmClient? {
        var firstError: String?
        for candidate in candidates {
            if let client = decode(candidate) { return client }
            if firstError == nil { firstError = lastError }
        }
        lastError = firstError
        return nil
    }
}

/// 凭据存储。原 APK 同时写内部文件、SharedPreferences 与外部私有目录；
/// iOS 侧等价做法是钥匙串 + 应用支持目录文件双写。
public final class GwmSecureStore: @unchecked Sendable {
    static let fileName = "doro_gwm_session.json"
    private let keychain: KeychainStore
    private let directory: URL
    private(set) public var lastLoadError: String?
    /// load() 内部会调用 save()/clear()，因此必须是递归锁。
    private let lock = NSRecursiveLock()

    public init(keychain: KeychainStore = KeychainStore(service: "com.dorocar.car.session"),
                directory: URL? = nil) {
        self.keychain = keychain
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("XiaoHaCar", isDirectory: true)
        }
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private func readFile() -> String? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeFile(_ text: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = fileURL.appendingPathExtension("tmp")
            try Data(text.utf8).write(to: temporary, options: .atomic)
            _ = try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: temporary, to: fileURL)
            return (try? Data(contentsOf: fileURL).isEmpty) == false
        } catch {
            return false
        }
    }

    public func load() -> GwmClient? {
        lock.lock(); defer { lock.unlock() }
        var codec = SessionCodec()
        let fileCopy = readFile()
        let keychainCopy = keychain.read()
        guard let client = codec.decodeFirst([fileCopy, keychainCopy]) else {
            lastLoadError = codec.lastError
            if hasCredentials() { clear() }
            return nil
        }
        lastLoadError = nil
        // 任一副本缺失时补齐，保证后续冷启动仍可恢复
        if fileCopy == nil || keychainCopy == nil {
            _ = save(client)
        }
        return client
    }

    public func save(_ client: GwmClient) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let state = GwmCrypto.encodeDotnetJSON(client.toStateMap())
        guard state.count >= 2 else { return false }
        let wrapped = SessionCodec.wrap(state)
        let fileOK = writeFile(wrapped)
        let keychainOK = keychain.write(wrapped)
        return fileOK || keychainOK
    }

    public func hasCredentials() -> Bool {
        if keychain.read() != nil { return true }
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty { return true }
        return false
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        _ = keychain.delete()
        _ = try? FileManager.default.removeItem(at: fileURL)
    }

    public func exportPlaintext() -> String? {
        guard let client = load() else { return nil }
        return GwmCrypto.encodeDotnetJSON(client.toStateMap())
    }
}

/// 钥匙串读写（iOS 用 Security 框架，测试环境退化为内存字典）。
public final class KeychainStore: @unchecked Sendable {
    private let service: String
    private let account = "session"
    private var memory: [String: String] = [:]
    private let lock = NSLock()

    public init(service: String) {
        self.service = service
    }

    public func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        query.removeAll()
        return String(decoding: data, as: UTF8.self)
        #else
        return memory[service]
        #endif
    }

    @discardableResult
    public func write(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Security)
        let data = Data(text.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        var insert = query
        insert.merge(attributes) { $1 }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        #else
        memory[service] = text
        return true
        #endif
    }

    @discardableResult
    public func delete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        memory.removeValue(forKey: service)
        return true
        #endif
    }
}
