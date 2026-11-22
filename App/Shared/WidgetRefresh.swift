import WidgetKit

/// 触发小组件刷新（需要 WidgetKit，不能在核心库里做）。
enum WidgetRefresh {
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
