import Foundation

/// 车辆条目，对应原 APK 的 GwmVehicle。
public struct GwmVehicle: Equatable, Sendable, Identifiable {
    public var vin: String
    public var modelName: String?
    public var seriesName: String?
    public var nickname: String?
    public var brandName: String?
    public var platform: String

    public var id: String { vin }

    public init(vin: String, modelName: String? = nil, seriesName: String? = nil,
                nickname: String? = nil, brandName: String? = nil, platform: String = "") {
        self.vin = vin
        self.modelName = modelName
        self.seriesName = seriesName
        self.nickname = nickname
        self.brandName = brandName
        self.platform = platform
    }

    public static func maskVin(_ vin: String?) -> String {
        guard let vin else { return "" }
        return vin.count <= 6 ? vin : "VIN …" + String(vin.suffix(6))
    }

    private static func notEmpty(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func displayName() -> String {
        if Self.notEmpty(nickname) { return nickname! }
        if Self.notEmpty(seriesName) { return seriesName! }
        if Self.notEmpty(modelName) { return modelName! }
        return vin.count < 6 ? "我的车辆" : "车辆 " + String(vin.suffix(6))
    }

    public func subtitle() -> String {
        subtitleWithPlatform(platform)
    }

    public func subtitleWithPlatform(_ override: String?) -> String {
        var parts: [String] = []
        parts.append(Self.maskVin(vin))
        if Self.notEmpty(modelName), modelName != nickname {
            parts.append(modelName!)
        }
        let effective = Self.notEmpty(override) ? override! : platform
        if Self.notEmpty(effective) {
            parts.append(effective)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
