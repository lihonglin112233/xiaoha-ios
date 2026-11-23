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
        // 内容撑满容器，按钮固定贴底
        VStack(spacing: 0) {
            header
                .padding(.bottom, 8)
            content
            Spacer(minLength: 6)
            actionRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(WidgetBackground())
    }

    // MARK: 头部（车名 + 引擎状态）

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.vehicleName)
                    .font(.system(size: family == .systemSmall ? 11 : 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let model = snapshot.modelName, !model.isEmpty, model != snapshot.vehicleName {
                    Text(model)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                Circle()
                    .fill(snapshot.engineRunning ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(snapshot.engineText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            smallContent
        case .systemLarge:
            largeContent
        default:
            mediumContent
        }
    }

    /// 小尺寸：只放指标 + 紧凑车身
    private var smallContent: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                metricRow
                tireLegend
            }
            Spacer(minLength: 0)
            carDiagram(width: 46, height: 82)
        }
    }

    /// 中尺寸：左侧指标，右侧车身
    private var mediumContent: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                metricRow
                if let range = snapshot.range {
                    Text("续航 \(Int(range)) km")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.teal)
                }
            }
            Spacer(minLength: 0)
            carDiagram(width: 62, height: 96)
                .padding(.trailing, 6)
        }
    }

    /// 大尺寸：指标 + 居中大车身
    private var largeContent: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                metricRow
                Spacer()
                if let range = snapshot.range {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("续航").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text("\(Int(range)) km")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.teal)
                    }
                }
            }
            Spacer(minLength: 2)
            carDiagram(width: 92, height: 150)
            Spacer(minLength: 2)
        }
    }

    private var metricRow: some View {
        HStack(spacing: 14) {
            metric("门锁", snapshot.locked.map { $0 ? "已锁" : "未锁" } ?? "--",
                   tint: snapshot.locked == true ? .green : .orange)
            metric("电量", snapshot.battery.map { "\(Int($0))%" } ?? "--", tint: .blue)
            if family == .systemLarge {
                metric("续航", snapshot.range.map { "\(Int($0)) km" } ?? "--", tint: .teal)
            }
        }
    }

    private var tireLegend: some View {
        Text("胎压 " + snapshot.tireTexts.joined(separator: " / "))
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: family == .systemLarge ? 16 : 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: 俯视车身 + 四轮胎压

    /// 车身上画四个轮位，胎压数值标在轮子外侧；告警轮用红色。
    private func carDiagram(width: CGFloat, height: CGFloat) -> some View {
        let texts = snapshot.tireTexts
        let alarms = snapshot.tireAlarms
        let bodyWidth = width * 0.56
        let tireW = width * 0.19
        let tireH = height * 0.15

        return ZStack {
            // 车身
            RoundedRectangle(cornerRadius: bodyWidth * 0.30)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: bodyWidth * 0.30)
                        .stroke(Color.accentColor.opacity(0.30), lineWidth: 1)
                )
                .frame(width: bodyWidth, height: height)
            // 前/后风挡
            VStack {
                RoundedRectangle(cornerRadius: bodyWidth * 0.10)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: bodyWidth * 0.62, height: height * 0.15)
                Spacer()
                RoundedRectangle(cornerRadius: bodyWidth * 0.10)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: bodyWidth * 0.62, height: height * 0.15)
            }
            .frame(height: height * 0.82)

            // 四个轮位
            tire(fl: true, top: true, texts: texts, alarms: alarms,
                 tireW: tireW, tireH: tireH, bodyWidth: bodyWidth, width: width, height: height)
            tire(fl: false, top: true, texts: texts, alarms: alarms,
                 tireW: tireW, tireH: tireH, bodyWidth: bodyWidth, width: width, height: height)
            tire(fl: true, top: false, texts: texts, alarms: alarms,
                 tireW: tireW, tireH: tireH, bodyWidth: bodyWidth, width: width, height: height)
            tire(fl: false, top: false, texts: texts, alarms: alarms,
                 tireW: tireW, tireH: tireH, bodyWidth: bodyWidth, width: width, height: height)
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func tire(fl: Bool, top: Bool, texts: [String], alarms: [Bool],
                      tireW: CGFloat, tireH: CGFloat, bodyWidth: CGFloat,
                      width: CGFloat, height: CGFloat) -> some View {
        let index = (top ? 0 : 2) + (fl ? 0 : 1)
        let alarm = alarms[index]
        let color: Color = alarm ? .red : .primary
        let offsetX = (bodyWidth / 2) + tireW / 2 + 1
        let sign: CGFloat = fl ? -1 : 1
        let yOffset = top ? -(height * 0.30) : (height * 0.30)
        HStack(spacing: 2) {
            if fl {
                Text(texts[index])
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(color)
            }
            RoundedRectangle(cornerRadius: tireW * 0.38)
                .fill(alarm ? Color.red.opacity(0.16) : Color.secondary.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: tireW * 0.38)
                        .stroke(color.opacity(alarm ? 0.85 : 0.35), lineWidth: 1)
                )
                .frame(width: tireW, height: tireH)
            if !fl {
                Text(texts[index])
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .offset(x: sign * offsetX * 0.62, y: yOffset)
    }

    // MARK: 底部四个按钮

    private var actionRow: some View {
        HStack(spacing: 7) {
            actionButton(.engineStart)
            actionButton(.lock)
            actionButton(.unlock)
            actionButton(.windowClose)
        }
    }

    @ViewBuilder
    private func actionButton(_ link: WidgetDeepLink) -> some View {
        if let url = link.url {
            Link(destination: url) {
                VStack(spacing: 3) {
                    Image(systemName: link.systemImage)
                        .font(.system(size: family == .systemLarge ? 15 : 13, weight: .medium))
                    Text(link.title)
                        .font(.system(size: family == .systemLarge ? 10 : 9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, family == .systemLarge ? 8 : 6)
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
