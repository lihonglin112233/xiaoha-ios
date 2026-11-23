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
            carDiagram(width: 104, height: 78)
        }
    }

    /// 中尺寸：左侧指标，右侧车身（图三布局）
    private var mediumContent: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                metricRow
                if let range = snapshot.range {
                    Text("续航 \(Int(range)) km")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.teal)
                }
            }
            .frame(width: 108, alignment: .leading)
            carDiagram(width: 160, height: 88)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
            carDiagram(width: 200, height: 150)
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

    /// 三栏布局：左文字栏 | 车身(含轮) | 右文字栏。
    /// 文字与车身之间留固定 gap，避免像之前那样被挤到贴着车。
    private func carDiagram(width: CGFloat, height: CGFloat) -> some View {
        let texts = snapshot.tireTexts
        let alarms = snapshot.tireAlarms

        let textW = width * 0.21
        let gap = width * 0.06          // 文字与轮胎之间的间距
        let tireW = max(5, width * 0.09)
        let tireH = max(8, height * 0.13)
        let bodyW = max(16, width - 2 * textW - 2 * gap - 2 * tireW)
        let wheelY = height * 0.30

        return HStack(alignment: .center, spacing: 0) {
            // 左侧胎压（左前 / 左后）
            tireTextColumn(texts: texts, alarms: alarms, indices: [0, 2],
                           isLeft: true, wheelY: wheelY)
                .frame(width: textW, height: height)
                .padding(.trailing, gap)

            // 车身 + 四轮
            ZStack {
                RoundedRectangle(cornerRadius: bodyW * 0.30)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: bodyW * 0.30)
                            .stroke(Color.accentColor.opacity(0.30), lineWidth: 1)
                    )
                    .frame(width: bodyW, height: height)

                // 前/后风挡示意
                VStack {
                    RoundedRectangle(cornerRadius: bodyW * 0.10)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: bodyW * 0.60, height: height * 0.15)
                    Spacer()
                    RoundedRectangle(cornerRadius: bodyW * 0.10)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: bodyW * 0.60, height: height * 0.15)
                }
                .frame(height: height * 0.80)

                // 轮胎：两个 HStack 分别放到前后轴，间距等于车宽
                HStack(spacing: bodyW) {
                    tireShape(alarm: alarms[0], tireW: tireW, tireH: tireH)
                    tireShape(alarm: alarms[1], tireW: tireW, tireH: tireH)
                }
                .offset(y: -wheelY)
                HStack(spacing: bodyW) {
                    tireShape(alarm: alarms[2], tireW: tireW, tireH: tireH)
                    tireShape(alarm: alarms[3], tireW: tireW, tireH: tireH)
                }
                .offset(y: wheelY)
            }
            .frame(width: bodyW + tireW * 2, height: height)

            // 右侧胎压（右前 / 右后）
            tireTextColumn(texts: texts, alarms: alarms, indices: [1, 3],
                           isLeft: false, wheelY: wheelY)
                .frame(width: textW, height: height)
                .padding(.leading, gap)
        }
        .frame(width: width, height: height)
    }

    /// 两个胎压读数：用 offset 精确对齐前后轮中心，避免布局弹性带来的偏移。
    private func tireTextColumn(texts: [String], alarms: [Bool], indices: [Int],
                                isLeft: Bool, wheelY: CGFloat) -> some View {
        ZStack {
            tireText(texts[indices[0]], alarm: alarms[indices[0]], isLeft: isLeft)
                .offset(y: -wheelY)
            tireText(texts[indices[1]], alarm: alarms[indices[1]], isLeft: isLeft)
                .offset(y: wheelY)
        }
    }

    private func tireText(_ value: String, alarm: Bool, isLeft: Bool) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(alarm ? Color.red : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: isLeft ? .trailing : .leading)
    }

    private func tireShape(alarm: Bool, tireW: CGFloat, tireH: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: tireW * 0.40)
            .fill(alarm ? Color.red.opacity(0.16) : Color.secondary.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: tireW * 0.40)
                    .stroke(alarm ? Color.red.opacity(0.85) : Color.secondary.opacity(0.35),
                            lineWidth: 1)
            )
            .frame(width: tireW, height: tireH)
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
