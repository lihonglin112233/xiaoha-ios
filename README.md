# 小哈车控 iOS 版

> 设备已越狱 / 装了 TrollStore？看 [TROLLSTORE.md](TROLLSTORE.md)，ad-hoc 签名即可安装，不需要开发者账号。

把原 Android APK（`com.dorocar.car`，小哈车控）的车辆控制能力移植到 iPhone 的 SwiftUI 工程。
Android 的 dex / 资源无法转换成 iOS 二进制，因此这里是**按原实现逐项重写**，而不是"格式转换"。

协议层不靠猜：所有签名、信封加密、状态字段解析都用反编译后的原 Java 代码实际运行结果为基准做逐字节/逐字段对拍。

## 目录结构

```
Sources/XiaoHaCore/          纯 Swift 核心库（无 UIKit 依赖，可在 Linux 跑测试）
  Support/                   Digest(MD5/SHA1/SHA256/HMAC) · AES(-CBC/PKCS7) · Base64 · JSON · Java 语义兼容
  Crypto/GwmCrypto.swift     签名（AutoAI HMAC-SHA1 / BeanTech SHA-256 / G-App defaultSign）与 G_A 信封
  Model/                     VehicleStatus 解析 · 车辆/动作/守卫（EngineGuard·HvacGuard·TempControl）· 结果判定
  Network/                   GwmClient（G-App + BeanTech + AutoAI 三通道）· 可注入 HTTPTransport
  Repository/                GwmRepository（登录/会话恢复/轮询）· CommandExecutor（编排与校验）· 状态提醒 · 语音解析
  Storage/                   凭据持久化（钥匙串 + 文件双写，带 sha1 校验）
App/XiaoHaCar/               SwiftUI 主界面
App/XiaoHaWidget/            桌面小组件
App/Intents/                 App Intents / Siri 语音车控
App/Shared/                  环境单例、后台刷新、通知
project.yml                  XcodeGen 工程定义
.github/workflows/build-ipa.yml   CI 出未签名 ipa
Tests/XiaoHaCoreTests/       62 项测试
```

## 怎么拿到 ipa

本机（Android 手机上的 Ubuntu）没有 macOS、Xcode 与 iOS SDK，**无法直接产出能安装的 ipa**；iOS 应用必须在 macOS 上编译。

两条路，任选一条：

### A. GitHub Actions（无需 Mac）

1. 把本目录推到 GitHub 仓库（`main` 分支）。
2. Actions 里的 `build-ipa` 会自动跑：Linux 单元测试 → macOS 编译 → 打包。
3. 下载产物 `XiaoHaCar-ipa`（内含 `XiaoHaCar-XiaoHaCar.ipa`）。

### B. 本机 Mac

```bash
brew install xcodegen
xcodegen generate
open XiaoHaCar.xcodeproj      # 用 Xcode 选自己的开发者账号直接 Run
```

或者命令行出未签名 ipa：

```bash
xcodebuild archive -project XiaoHaCar.xcodeproj -scheme XiaoHaCar \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/XiaoHaCar.xcarchive \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
mkdir -p build/Payload && cp -R build/XiaoHaCar.xcarchive/Products/Applications/*.app build/Payload/
cd build && zip -qry XiaoHaCar-XiaoHaCar.ipa Payload
```

### C. 装到 iPhone

- **已越狱 / 有 TrollStore**：直接把 ipa 交给 TrollStore 安装，不过期、无需账号。详见 [TROLLSTORE.md](TROLLSTORE.md)。
- **普通设备**：用 Sideloadly / AltStore 填任意 Apple ID 自签安装，免费账号 7 天过期需续签。

## 与 Android 版的对应关系

| Android | iOS | 说明 |
| --- | --- | --- |
| `GwmClient` | `Sources/XiaoHaCore/Network/GwmClient.swift` | 三通道登录、指令下发、状态查询、550002 自动降级 gtsp |
| `GwmCrypto` | `Sources/XiaoHaCore/Crypto/GwmCrypto.swift` | 全部签名与 G_A(OpenSSL `Salted__` 风格) 信封 |
| `GwmRepository` | `Sources/XiaoHaCore/Repository/GwmRepository.swift` | 登录、静默恢复、失败退避轮询（上限 10 分钟） |
| `CommandExecutor` | `Sources/XiaoHaCore/Repository/CommandExecutor.swift` | 顺序下发、4 秒轮询校验、48 秒超时、锁车自动补发关窗/关天窗 |
| `CommandOutcome` | `Sources/XiaoHaCore/Model/CommandOutcome.swift` | 结果探针与"部分完成/无法校验"文案 |
| `StatusAlertCenter` | `Sources/XiaoHaCore/Repository/StatusAlertCenter.swift` | 门锁/车窗/后备箱/发动机/空调变化 + 电量续航分档提醒 |
| `VehiclePollService` | `App/Shared/BackgroundPoller.swift` | iOS 限制：前台 60 秒定时器 + `BGAppRefreshTask`（实际间隔由系统决定，通常 ≥15 分钟） |
| `CarWidgetProvider` | `App/XiaoHaWidget/CarWidget.swift` | 桌面小组件，经 App Group 共享快照 |
| `ChatCommandBridge` | `Sources/XiaoHaCore/Repository/ChatCommandBridge.swift` + `App/Intents/CarIntents.swift` | 同样的关键词优先级与温度解析，接到 Siri / 快捷指令 |
| 微信广播桥 `BridgeBus` | 未移植 | Android 专有的跨 App 广播，iOS 无对应机制（见下） |

## 行为差异（重要，不是遗漏）

1. **后台轮询频率**：Android 前台服务可 60 秒一次常驻；iOS 进入后台后只能靠 `BGAppRefreshTask`，由系统调度，通常十几分钟到数小时，且低电量模式下可能完全不触发。前台打开 App 时仍为 60 秒。
2. **微信远程指令**：原版通过 `com.dorocar.car.bridge.IN` 广播接收微信消息并用 `ChatCommandBridge` 解析。iOS 不允许跨 App 收发广播，等价能力改为 Siri / 快捷指令 / 小组件按钮。
3. **推送**：原版是本地通知；这里同样是本地通知，不依赖服务器。若需要 App 未运行时的即时提醒，需要自建推送服务端。
4. **凭据存储**：Android 是 SharedPreferences + 文件 + 外部私有目录三写；iOS 改为钥匙串 + 应用支持目录双写，语义等价（任一可用即恢复）。

## 测试

```bash
swift test          # 62 项，Linux / macOS 均可
```

测试分四层：

- **黄金向量**：把反编译出的 `GwmCrypto` / `Base64Codec` / `JsonLite` 直接编译运行，产出 MD5/SHA-256/HMAC、三种签名、G_A 加解密、.NET 风格 JSON、URL 编码的期望值，Swift 侧逐项比对。
- **状态解析基准**：8 组真实形态报文（含字段名大小写差异、`2.5,bar`、`--`、`245` 分度温度）由原 Java `VehicleStatus` 反射输出全部非空字段，Swift 逐字段比对。
- **协议流程**：注入 `StubTransport` 回放 JSON，校验请求方法/路径/头部签名可复算、登录体确实被 G_A 加密、beantech 与 timely 分路径、`-114` 与 `550002` 处理、风控 1013。
- **编排与判定**：锁车链自动补发关车窗/关天窗、守卫拦截不发包、车况确认变化判成功、无变化超时判未生效。

## 免责声明

本工程仅复刻原 App 已有的本机功能，接口凭据与常量均来自原 APK 内嵌值，未做任何绕过或破解。
使用他人账号 / 车辆前请确认你有合法授权；车辆远程控制涉及安全，请自行评估风险。
