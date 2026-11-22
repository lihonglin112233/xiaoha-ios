# 用 TrollStore 装到 iPhone

你的设备已装巨魔（TrollStore），签名可以完全跳过：TrollStore 接受 **ad-hoc 签名**（自己给自己签，没有证书、没有开发者账号、不过期）。
但它**不接受完全未签名的包**，所以 CI 会做 ad-hoc 签名，这一步不需要你提供任何凭据。

## 唯一的硬性前提：ipa 必须由 Apple 工具链编译

ipa 里的 `小哈车控.app/小哈车控` 是 arm64 Mach-O 可执行文件，必须用 iOS SDK 链接产生。
iOS SDK 只随 Xcode 分发，本工程的开发环境（Android 手机上的 Ubuntu）没有它，无法生成这个文件。
换成"不签名"并不会绕过这一点。

所以流程是：**GitHub 编译一次 → 下载 ipa → 拖进 TrollStore**。

## 步骤

### 1. 推仓库

```bash
cd xiaoha-ios
git init && git add . && git commit -m "小哈车控 iOS"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

`main` 一推上去，`.github/workflows/build-ipa.yml` 自动开始跑（也可以在 Actions 页面点 `Run workflow`）。

### 2. 等 CI 出包

流程约 5–10 分钟，依次执行：

1. Linux 上跑 62 项单元测试（不通过就不会继续编译）
2. macOS runner 上 `xcodegen generate`
3. `xcodebuild archive`（ad-hoc 签名）
4. 对扩展和主 App `codesign --sign -`
5. 打包 `Payload/` → `XiaoHaCar.ipa`

在 Actions run 页面底部 **Artifacts → XiaoHaCar-ipa** 下载。

### 3. 装进 TrollStore

任选其一：

- **TrollStore 内安装**：把 `.ipa` 存到「文件」App，长按 → 共享 → TrollStore；或在 TrollStore 里点右上角 `+` → 选择 ipa。
- **隔空投送/网盘**：传到手机后用 TrollStore 打开该文件。
- 命令行（设备已 SSH 时）：`ipainstaller XiaoHaCar.ipa`

装完桌面出现「小哈车控」，与普通 App 一样常驻、不过期。

## 关于扩展与权限

- **桌面小组件**：ad-hoc 签名下 App Group 有时拿不到（没有 provisioning profile 时系统可能拒绝）。代码已做降级：拿不到就不显示陈旧数据，不会崩溃。若小组件空白，属于这个原因，App 主界面功能不受影响。
- **Siri / 快捷指令**：App Intents 不需要额外权限，装好后可在「快捷指令」里搜到「锁车」「解锁」「开空调」「远程启动」。
- **后台刷新**：TrollStore 安装的 App 与正常 App 的后台限制相同，`BGAppRefreshTask` 仍由系统调度；但因为是常驻安装（不会像免费签名那样 7 天后失效），长期可用性反而更好。

## 如果 CI 失败

常见原因与处理：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `unable to resolve package dependencies` | 首次未解析 SPM | 工作流已含 `-resolvePackageDependencies`，重跑一次 |
| `Xcode_16.0.app not found` | runner 镜像版本变化 | 工作流里已 fallback 到 `/Applications/Xcode.app`，或改 `xcode-select` 的版本名 |
| `Signing for "XiaoHaCar" requires a development team` | 签名参数未生效 | 确认 archive 参数里有 `CODE_SIGNING_ALLOWED=YES` 且 `DEVELOPMENT_TEAM=""` |
| 装到设备后闪退 | 缺 `BGTaskSchedulerPermittedIdentifiers` | 已在 `project.yml` 的 `info.properties` 中声明 `com.xiaoha.car.refresh` |
| TrollStore 提示不支持 | 包里是未签名二进制 | 确认用的是 CI 产出的 `XiaoHaCar.ipa`，不是自行 `zip` 的骨架 |

## 无需 TrollStore 的替代路径

没有巨魔的设备可以用 Sideloadly 填任意 Apple ID 签名安装，免费账号 7 天需续签；工程代码完全一样，不需要改动。
