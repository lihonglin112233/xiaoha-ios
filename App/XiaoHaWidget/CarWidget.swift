import WidgetKit
import SwiftUI
import XiaoHaCore

struct CarEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CarTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarEntry {
        CarEntry(date: Date(), snapshot: WidgetSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (CarEntry) -> Void) {
        completion(CarEntry(date: Date(), snapshot: WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CarEntry>) -> Void) {
        let entry = CarEntry(date: Date(), snapshot: WidgetStore.load())
        // WidgetKit 由系统调度，15 分钟是合理下限
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

// MARK: - 主视图

struct CarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CarEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        // 关键：内容必须撑满整个 widget 容器，否则背景会收缩、内容堆在左上角。
        layout
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(WidgetBackground())
    }

    @ViewBuilder
    private var layout: some View {
        switch family {
        case .systemSmall:
            smallLayout
        case .systemLarge:
            largeLayout
        default:
            mediumLayout
        }
    }

    // MARK: 小尺寸：标题 + 三项指标

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 12) {
                metric("门锁", snapshot.locked.map { $0 ? "已锁" : "未锁" } ?? "--",
                       tint: snapshot.locked == true ? .green : .orange)
                metric("电量", snapshot.battery.map { "\(Int($0))%" } ?? "--", tint: .blue)
            }
            Spacer(minLength: 8)
            HStack {
                metric("续航", snapshot.range.map { "\(Int($0)) km" } ?? "--", tint: .teal)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    // MARK: 中尺寸：状态 + 4 个按钮（启动/锁车/解锁/关窗）

    private var mediumLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    HStack(spacing: 16) {
                        metric("门锁", snapshot.locked.map { $0 ? "已锁" : "未锁" } ?? "--",
                               tint: snapshot.locked == true ? .green : .orange)
                        metric("电量", snapshot.battery.map { "\(Int($0))%" } ?? "--", tint: .blue)
                        metric("续航", snapshot.range.map { "\(Int($0)) km" } ?? "--", tint: .teal)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    engineBadge
                    Text(entry.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)

            Spacer(minLength: 6)
            actionRow
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    // MARK: 大尺寸：同中尺寸但留白更多

    private var largeLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    HStack(spacing: 22) {
                        metric("门锁", snapshot.locked.map { $0 ? "已锁" : "未锁" } ?? "--",
                               tint: snapshot.locked == true ? .green : .orange)
                        metric("电量", snapshot.battery.map { "\(Int($0))%" } ?? "--", tint: .blue)
                        metric("续航", snapshot.range.map { "\(Int($0)) km" } ?? "--", tint: .teal)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    engineBadge
                    if snapshot.acOn == true {
                        Label("空调开", systemImage: "snowflake")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                    Text(entry.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            Spacer(minLength: 8)
            actionRow
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    // MARK: - 组件

    private var header: some View {
        Text(snapshot.vehicleName)
            .font(.caption.bold())
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var engineBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(snapshot.engineRunning ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(snapshot.engineText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 四个动作按钮：远程启动、锁车、解锁、关车窗。
    private var actionRow: some View {
        HStack(spacing: 8) {
            actionButton(.engineStart)
            actionButton(.lock)
            actionButton(.unlock)
            actionButton(.windowClose)
        }
    }

    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// iOS 16 不支持小组件 AppIntent 按钮，统一用深链唤起 App 执行。
    @ViewBuilder
    private func actionButton(_ link: WidgetDeepLink) -> some View {
        if let url = link.url {
            Link(destination: url) {
                VStack(spacing: 4) {
                    Image(systemName: link.systemImage)
                        .font(.system(size: 15, weight: .medium))
                    Text(link.title)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}

// MARK: - 背景

/// 背景必须铺满整个 widget。iOS 17 用 containerBackground，iOS 16 用铺满的 background。
struct WidgetBackground: ViewModifier {
    private var gradient: LinearGradient {
        LinearGradient(colors: [Color(.systemBackground), Color.accentColor.opacity(0.10)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(for: .widget) { gradient }
        } else {
            content.background(gradient.ignoresSafeArea())
        }
    }
}

@main
struct XiaoHaWidgetBundle: WidgetBundle {
    var body: some Widget {
        CarControlWidget()
    }
}

struct CarControlWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CarControlWidget", provider: CarTimelineProvider()) { entry in
            CarWidgetView(entry: entry)
        }
        .configurationDisplayName("小哈车控")
        .description("查看车况，并直接远程启动、锁车、解锁、关车窗。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
