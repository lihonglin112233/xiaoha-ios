import WidgetKit
import SwiftUI
import XiaoHaCore

/// 桌面小组件，对应 Android 的 CarWidgetProvider。
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
        // 系统会合并刷新，15 分钟一次是 WidgetKit 的合理下限
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CarWidgetView: View {
    let entry: CarEntry

    var body: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.vehicleName).font(.caption.bold()).lineLimit(1)
                Spacer()
                Circle()
                    .fill(snapshot.engineRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
            }
            HStack(spacing: 12) {
                metric("门锁", snapshot.locked.map { $0 ? "已锁" : "未锁" } ?? "--",
                       tint: snapshot.locked == true ? .green : .orange)
                metric("电量", snapshot.battery.map { "\(Int($0))%" } ?? "--", tint: .blue)
                metric("续航", snapshot.range.map { "\(Int($0)) km" } ?? "--", tint: .teal)
            }
            HStack(spacing: 4) {
                Image(systemName: snapshot.engineRunning ? "engine.combustion.fill" : "engine.combustion")
                    .font(.caption2)
                Text(snapshot.engineText).font(.caption2)
                if snapshot.acOn == true {
                    Image(systemName: "snowflake").font(.caption2)
                }
                Spacer()
                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(.systemBackground), Color.accentColor.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.caption.bold().monospacedDigit()).foregroundStyle(tint)
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
        .description("查看车辆门锁、电量与续航。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
