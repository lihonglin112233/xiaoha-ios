import Foundation
import XiaoHaCore

/// 小组件深链：iOS 16 的小组件不支持交互按钮（那是 iOS 17 的 AppIntent 能力），
/// 因此在 iOS 16 上改为"点按钮 → 用深链唤起 App → App 内立即执行"。
/// 对应原 Android 小组件的 8 个动作。
public enum WidgetDeepLink: String, CaseIterable, Sendable {
    case lock
    case unlock
    case acOn
    case acOff
    case engineStart
    case engineStop
    case windowClose
    case refresh

    public static let scheme = "xiaohacar"

    public var url: URL? {
        URL(string: "\(Self.scheme)://action/\(rawValue)")
    }

    public var title: String {
        switch self {
        case .lock: return "锁车"
        case .unlock: return "解锁"
        case .acOn: return "开空调"
        case .acOff: return "关空调"
        case .engineStart: return "远程启动"
        case .engineStop: return "远程熄火"
        case .windowClose: return "关车窗"
        case .refresh: return "刷新"
        }
    }

    public var systemImage: String {
        switch self {
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .acOn: return "snowflake"
        case .acOff: return "power"
        case .engineStart: return "play.fill"
        case .engineStop: return "stop.fill"
        case .windowClose: return "wind"
        case .refresh: return "arrow.clockwise"
        }
    }

    /// 解析深链，返回要执行的动作。
    public static func parse(_ url: URL) -> WidgetDeepLink? {
        guard url.scheme == scheme else { return nil }
        // 支持 xiaohacar://action/lock
        let parts = url.path.split(separator: "/").map(String.init)
        if url.host == "action", let name = parts.first {
            return WidgetDeepLink(rawValue: name)
        }
        // 兼容 xiaohacar://lock
        if let host = url.host, let link = WidgetDeepLink(rawValue: host) {
            return link
        }
        return nil
    }

    /// 映射到可执行的车控动作（refresh 不产生指令）。
    public var vehicleAction: VehicleAction? {
        switch self {
        case .lock: return .lock
        case .unlock: return .unlock
        case .acOn: return .acOn
        case .acOff: return .acOff
        case .engineStart: return .engineStart
        case .engineStop: return .engineStop
        case .windowClose: return .windowClose
        case .refresh: return nil
        }
    }
}
