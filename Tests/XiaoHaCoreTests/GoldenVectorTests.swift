import XCTest
@testable import XiaoHaCore

/// 与 Java 原实现（从 APK 反编译后直接编译运行）产出的基准值逐项比对。
final class GoldenVectorTests: XCTestCase {
    static var golden: [String: String] = [:]

    override class func setUp() {
        super.setUp()
        let url = Bundle.module.url(forResource: "golden", withExtension: "tsv")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("golden.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("无法读取基准文件: \(url.path)")
            return
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            golden[String(parts[0])] = String(parts[1])
        }
    }

    func expect(_ key: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let expected = Self.golden[key] else {
            XCTFail("缺少基准值: \(key)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, "向量 \(key) 不一致", file: file, line: line)
    }

    func testDigests() {
        expect("md5Hex", GwmCrypto.md5Hex("hello中文"))
        expect("sha256Hex", GwmCrypto.sha256Hex("hello中文"))
        expect("toHexUpper", Hex.encodeUpper([0xDE, 0xAD, 0x0F, 0xFF]))
    }

    func testSignatures() {
        expect("autoAiSign", GwmCrypto.autoAiSign("1700000000000"))
        expect("beanTechSign1", GwmCrypto.beanTechSign("POST", "/app-api/api/v1.0/vehicle/T5/sendCmd", "NONCE123", "1700000000123", "json={\"a\":1}"))
        expect("beanTechSign2", GwmCrypto.beanTechSign("post", "/app-api/api/v3.0/vehicle/getLastStatus", "n-2", "1700000000456", "vin=LGXC0000000000000"))
    }

    func testDefaultSign() {
        let headers = [
            "Timestamp": "1700000000123",
            "Authorization": "AUTH-TOKEN-ABCDEF",
            "DeviceId": "0A1B2C",
            "AppId": GwmCrypto.gAppAppId,
            "NoteId": GwmCrypto.defaultNoteId,
            "SourceApp": "GWM",
            "SourceAppVer": GwmCrypto.sourceAppVersion,
            "SourceType": "ANDROID",
        ]
        expect("defaultSignPost", GwmCrypto.defaultSign("POST", "https://gapp-api.gwmapp-h.com/gcar/v1/app/android/vehicle/query-vehicle-list", "{\"vehicleVersion\":13}", headers))
        expect("defaultSignGet", GwmCrypto.defaultSign("get", "u", nil, headers))
    }

    func testDeriveSecret() {
        expect("deriveSecret0", GwmCrypto.deriveSecret("1700000000123", "0A1B2C4D5E6F", "Bearer abcdefghijklmn"))
        expect("deriveSecret1", GwmCrypto.deriveSecret("1700000000124", "0A1B2C4D5E6F", "Bearer abcdefghijklmn"))
        expect("deriveSecret2", GwmCrypto.deriveSecret("1700000000125", nil, nil))
        expect("deriveSecret3", GwmCrypto.deriveSecret("notanumber", "ZZZZZZZZZZZZ", " short "))
        expect("deriveSecret4", GwmCrypto.deriveSecret("1700432000999", "AAAAAABBBBBB", "0123456789ABCDEF"))
    }

    func testEnvelope() throws {
        let salt1: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let salt2: [UInt8] = [9, 8, 7, 6, 5, 4, 3, 2]
        expect("encEnvelope1", try GwmCrypto.encryptEnvelope("{\"phone\":\"13800000000\"}", keyId: 1, salt: salt1))
        expect("encEnvelope2", try GwmCrypto.encryptEnvelope("{\"x\":\"值\"}", keyId: 2, salt: salt2))
        let roundTripSalt: [UInt8] = [42, 1, 2, 3, 4, 5, 6, 7]
        let envelope = try GwmCrypto.encryptEnvelope("{\"k\":\"v\",\"n\":1}", keyId: 1, salt: roundTripSalt)
        expect("decRoundTrip", try GwmCrypto.decryptEnvelope(envelope) ?? "nil")
    }

    func testDotnetJSON() {
        var inner: [(String, JSONValue)] = []
        inner.append(("b", .number(1)))
        inner.append(("a", .string("x<y&z'q\"w")))
        inner.append(("c", .null))
        inner.append(("d", .bool(true)))
        inner.append(("e", .number(12.5)))
        inner.append(("f", .string("\u{01}\u{7F}中")))
        inner.append(("g", .array([.number(3), .string("t"), .null])))
        let root: JSONValue = .object([("z", .object(inner)), ("num", .number(7))])
        expect("dotnetJson", GwmCrypto.encodeDotnetJSON(root))
    }

    func testURLEncode() {
        expect("urlEncode", JavaURL.javaUrlEncode("a b+c*d~e/f?g=h&i=j中文"))
    }
}
