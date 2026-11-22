import SwiftUI
import XiaoHaCore

struct ControlView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showEngineStartConfirm = false
    @State private var showEngineStopConfirm = false
    @State private var showLogoutConfirm = false
    @State private var phone = ""
    @State private var password = ""
    @State private var code = ""
    @State private var sendingCode = false
    @State private var loggingIn = false
    @State private var countdown = 0
    @State private var timer: Timer?

    private var status: VehicleStatus? { env.status }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    if !env.isLoggedIn { loginCard } else { controlCards }
                    if let banner = env.banner { bannerView(banner) }
                    if let progress = env.progressText { Text(progress).font(.footnote).foregroundStyle(.secondary) }
                    alertsSection
                    helpLink
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("小哈车控")
            .toolbar {
                if env.isLoggedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("退出") { showLogoutConfirm = true }
                    }
                }
            }
            .confirmationDialog("退出登录", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出", role: .destructive) { env.logout() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("退出后将停止状态提醒与远控，需重新用短信验证码登录。")
            }
            .confirmationDialog("确认远程启动？", isPresented: $showEngineStartConfirm, titleVisibility: .visible) {
                Button("启动") { startEngine() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(EngineGuard.canStart(status).message + "\n\n发动机将运行 \(env.runMinutes) 分钟。")
            }
            .confirmationDialog("确认远程熄火？", isPresented: $showEngineStopConfirm, titleVisibility: .visible) {
                Button("熄火", role: .destructive) { env.perform(.engineStop) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("车辆将立即熄火，空调等附件也会停止工作。")
            }
            .task { env.start() }
        }
    }

    // MARK: - 顶部状态

    private var headerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(env.vehicles.first { $0.vin == env.repository.selectedVin() }?.displayName() ?? "我的车辆")
                            .font(.headline)
                        Text(env.vehicles.first { $0.vin == env.repository.selectedVin() }?.subtitle()
                             ?? (env.isLoggedIn ? "未选择车辆" : "未登录"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(env.isLoggedIn ? "已登录" : "未登录")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(env.isLoggedIn ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                        .foregroundStyle(env.isLoggedIn ? .green : .secondary)
                        .clipShape(Capsule())
                }
                if let status {
                    HStack(spacing: 18) {
                        MetricView(title: "门锁", value: status.doorsLocked.map { $0 ? "已锁" : "未锁" } ?? "--",
                                   tint: status.doorsLocked == true ? .green : .orange)
                        MetricView(title: "电量", value: status.batteryPercent.map { "\(Int($0))%" } ?? "--", tint: .blue)
                        MetricView(title: "续航", value: status.fuelRange.map { "\(Int($0)) km" } ?? "--", tint: .teal)
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(env.isRefreshing ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(refreshText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        env.repository.refreshNow()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise").font(.caption)
                    }
                }
                if let error = env.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let reauth = env.reauthMessage {
                    Text(reauth).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var refreshText: String {
        if env.isRefreshing { return "正在同步车况…" }
        guard let last = env.lastUpdateAt else { return "尚未同步" }
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return "更新于 " + formatter.string(from: last)
    }

    // MARK: - 登录

    private var loginCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("登录小哈账号").font(.subheadline.bold())
                TextField("手机号", text: $phone)
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码（可选，填了就用密码登录）", text: $password)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("短信验证码", text: $code)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button(sendingCode ? "发送中…" : (countdown > 0 ? "\(countdown)s" : "获取验证码")) {
                        sendCode()
                    }
                    .font(.footnote)
                    .disabled(sendingCode || countdown > 0)
                }
                Button {
                    login()
                } label: {
                    Text(loggingIn ? "登录中…" : "登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(loggingIn)
            }
        }
    }

    private func sendCode() {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 11 else {
            env.banner = .init(text: "请输入 11 位手机号", isError: true)
            return
        }
        sendingCode = true
        env.requestSmsCode(phone: trimmed) { ok, _ in
            sendingCode = false
            if ok {
                env.banner = .init(text: "验证码已发送，请查收", isError: false)
                startCountdown()
            }
        }
    }

    private func startCountdown() {
        countdown = 60
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if countdown > 0 { countdown -= 1 } else { timer?.invalidate() }
        }
    }

    private func login() {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 11 else {
            env.banner = .init(text: "请输入 11 位手机号", isError: true)
            return
        }
        if password.isEmpty && code.trimmingCharacters(in: .whitespaces).isEmpty {
            env.banner = .init(text: "请填写验证码，或输入密码登录", isError: true)
            return
        }
        loggingIn = true
        env.login(phone: trimmed, password: password, code: code) { _, _ in
            loggingIn = false
        }
    }

    // MARK: - 车控

    private var controlCards: some View {
        VStack(spacing: 14) {
            vehiclePicker
            securityCard
            engineCard
            hvacCard
            manualCard
        }
    }

    private var vehiclePicker: some View {
        Group {
            if env.vehicles.count > 1 {
                Card {
                    Picker("车辆", selection: Binding(
                        get: { env.repository.selectedVin() ?? "" },
                        set: { env.setSelectedVin($0) }
                    )) {
                        ForEach(env.vehicles) { vehicle in
                            Text(vehicle.displayName()).tag(vehicle.vin)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var securityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("安全").font(.subheadline.bold())
                Text(status?.securitySummary() ?? "车况未同步").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ActionButton(title: "锁车", systemImage: "lock.fill", tint: .blue) {
                        env.perform(.lock)
                    }
                    ActionButton(title: "解锁", systemImage: "lock.open.fill", tint: .orange) {
                        env.perform(.unlock)
                    }
                    ActionButton(title: "鸣笛", systemImage: "speaker.wave.2.fill", tint: .purple) {
                        env.perform(.whistle)
                    }
                    ActionButton(title: "闪灯", systemImage: "light.max", tint: .yellow) {
                        env.perform(.flash)
                    }
                }
            }
        }
    }

    private var engineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("发动机").font(.subheadline.bold())
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(status?.isEngineRunning() == true ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(status.map { "\($0.engineText())" } ?? "--")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(EngineGuard.hint(status)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        let verdict = EngineGuard.canStart(status)
                        if !verdict.allowed {
                            env.banner = .init(text: verdict.message, isError: true)
                        } else if verdict.needsConfirm {
                            showEngineStartConfirm = true
                        } else {
                            startEngine()
                        }
                    } label: {
                        Text("远程启动").frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(status?.isEngineRunning() == true && status?.engineState != nil)

                    Button {
                        let verdict = EngineGuard.canStop(status)
                        if !verdict.allowed {
                            env.banner = .init(text: verdict.message, isError: true)
                        } else {
                            showEngineStopConfirm = true
                        }
                    } label: {
                        Text("远程熄火").frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    cycleRunMinutes()
                } label: {
                    Label("运行 \(env.runMinutes) 分钟", systemImage: "clock")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func cycleRunMinutes() {
        let options = VehicleAction.runMinuteOptions
        let index = options.firstIndex(of: env.runMinutes) ?? 0
        env.runMinutes = options[(index + 1) % options.count]
    }

    private func startEngine() {
        env.perform(.engineStart, minutes: env.runMinutes)
    }

    private var hvacCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("空调").font(.subheadline.bold())
                    Spacer()
                    Text(acStateText).font(.caption).foregroundStyle(acTint)
                }
                Text(cabinText).font(.caption).foregroundStyle(.secondary)
                Text(HvacGuard.hint(status)).font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ActionButton(title: "开空调", systemImage: "snowflake", tint: .cyan) {
                        env.perform(.acOn, body: TempControl.bodiesOf(env.pendingTemp, zone: env.tempZone))
                    }
                    ActionButton(title: "关空调", systemImage: "power", tint: .gray) {
                        env.perform(.acOff)
                    }
                }
                let platform = env.platformForSelectedVehicle()
                let auxEnabled = HvacGuard.platformSupportsAux(platform)
                HStack(spacing: 10) {
                    ActionButton(title: "前除霜", systemImage: "car.side.front.open", tint: .blue, enabled: auxEnabled) {
                        env.perform(.defrostFront)
                    }
                    ActionButton(title: "后除霜", systemImage: "car.side.rear.open", tint: .blue, enabled: auxEnabled) {
                        env.perform(.defrostRear)
                    }
                    ActionButton(title: "方向盘加热", systemImage: "steeringwheel", tint: .orange, enabled: auxEnabled) {
                        env.perform(.steerHeat)
                    }
                }
                if !auxEnabled {
                    Text(HvacGuard.unsupportedPlatformText(platform))
                        .font(.caption).foregroundStyle(.orange)
                }

                Divider()

                HStack {
                    Text(TempControl.format(env.pendingTemp, fahrenheit: env.fahrenheit))
                        .font(.title3.bold().monospacedDigit())
                    Spacer()
                    Button { stepTemp(-1) } label: {
                        Image(systemName: "minus.circle.fill").font(.title2)
                    }
                    .disabled(TempControl.atMin(env.pendingTemp))
                    Button { stepTemp(1) } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .disabled(TempControl.atMax(env.pendingTemp))
                }
                HStack {
                    Button(env.tempZone.label) {
                        env.tempZone = env.tempZone.next
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    Button(env.fahrenheit ? "°F" : "°C") {
                        env.fahrenheit.toggle()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    Spacer()
                    Button("下发温度") {
                        env.perform(.acTempSet, body: TempControl.bodiesOf(env.pendingTemp, zone: env.tempZone))
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                }
                Text(tempHint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var acStateText: String {
        guard let status else { return "--" }
        guard let ac = status.airConditioner else { return "该车型无空调状态" }
        return ac ? "● 空调运行中" : "○ 空调已关闭"
    }

    private var acTint: Color {
        status?.airConditioner == true ? .green : .secondary
    }

    private var cabinText: String {
        guard let status else { return "车内温度 --" }
        var parts = ["车内温度 " + (status.cabinTemp.map { JavaMathText.fixed($0, 1) + "°C" } ?? "--")]
        if status.acAutoMode == true { parts.append("AUTO") }
        if status.frontDefroster == true { parts.append("前除霜") }
        if status.rearDefroster == true { parts.append("后除霜") }
        if status.steerWheelHeat == true { parts.append("方向盘加热") }
        return parts.joined(separator: " · ")
    }

    private var tempHint: String {
        guard let status else { return "车况未同步，下发后无法确认结果" }
        if let set = status.acTempSet {
            return "当前设定 " + TempControl.format(set, fahrenheit: env.fahrenheit)
        }
        return "该车型不回读设定温度，下发后无法确认是否生效"
    }

    private func stepTemp(_ delta: Double) {
        let next = delta > 0 ? TempControl.up(env.pendingTemp) : TempControl.down(env.pendingTemp)
        if abs(next - env.pendingTemp) < 0.001 {
            env.banner = .init(text: delta > 0 ? "已到最高温" : "已到最低温", isError: false)
        } else {
            env.setTemp(next)
        }
    }

    private var manualCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("其他").font(.subheadline.bold())
                HStack(spacing: 10) {
                    ActionButton(title: "关车窗", systemImage: "wind", tint: .indigo) {
                        env.perform(.windowClose)
                    }
                    ActionButton(title: "刷新车况", systemImage: "arrow.triangle.2.circlepath", tint: .green) {
                        env.refreshSnapshot()
                        env.repository.refreshNow()
                    }
                }
                Divider()
                Toggle(isOn: Binding(
                    get: { env.pollEnabled },
                    set: { env.setPollEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("后台监控").font(.subheadline)
                        Text(env.pollEnabled
                             ? "前台每 60 秒同步，后台由系统按需唤醒"
                             : "开启后车况变化会推送提醒")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 提醒与说明

    private var alertsSection: some View {
        Group {
            if !env.alerts.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(env.unread > 0 ? "状态提醒 (\(env.unread))" : "状态提醒")
                                .font(.subheadline.bold())
                            Spacer()
                            Button("清空") {
                                env.clearAlerts()
                            }
                            .font(.caption)
                        }
                        ForEach(Array(env.alerts.suffix(8).enumerated()), id: \.offset) { _, alert in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(alert.good ? Color.green : Color.orange)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                Text(alert.text).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    private var helpLink: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("使用说明").font(.subheadline.bold())
                Text("状态提醒：登录后开启监控，前台每 60 秒同步一次车况；iOS 进入后台后由系统按需唤醒（通常 15 分钟以上一次），变化会本地推送。\n\n远程启动：启动前会检查车门与电量，可选 10/15/20/30 分钟。\n\n空调控制：车辆启动后才能开空调、除霜、方向盘加热；关空调不受限制。\n\n结果以车况字段是否变化为准，回读不到的项会提示“无法确认”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bannerView(_ banner: AppEnvironment.Banner) -> some View {
        Text(banner.text)
            .font(.footnote)
            .foregroundStyle(banner.isError ? .red : .green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background((banner.isError ? Color.red : Color.green).opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 格式化辅助（避免视图层依赖内部工具）。
enum JavaMathText {
    static func fixed(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold().monospacedDigit()).foregroundStyle(tint)
        }
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 17))
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(tint.opacity(enabled ? 0.13 : 0.05))
            .foregroundStyle(enabled ? tint : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!enabled)
    }
}
