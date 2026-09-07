# 宿主接入指南

ShortcutLauncher 是 macOS Swift Package，提供两个 library product：

- `ShortcutLauncherCore`：数据模型、配置验证、持久化、事务和公开宿主契约。
- `ShortcutLauncherUI`：AppKit/SwiftUI 面板、Carbon 全局快捷键、目标选择与打开、应用搜索和网站图标。

`ShortcutLauncherUI` 依赖 Core。只使用模型和配置工具的宿主可以只依赖 Core；显示面板或注册系统快捷键时需要同时依赖两者。

## 添加依赖

在 Xcode 中选择 **File > Add Package Dependencies**，添加本地目录或仓库地址，然后给宿主 target 添加 `ShortcutLauncherCore` 和 `ShortcutLauncherUI`。

使用 Swift Package manifest 时：

```swift
dependencies: [
  .package(url: "<repository-url>", .upToNextMinor(from: "0.6.0"))
],
targets: [
  .target(
    name: "HostApp",
    dependencies: [
      .product(name: "ShortcutLauncherCore", package: "ShortcutLauncher"),
      .product(name: "ShortcutLauncherUI", package: "ShortcutLauncher")
    ]
  )
]
```

本地迁移时可以先把仓库放在宿主的 `Vendor/ShortcutLauncher`，再由 Xcode 添加 Local Package。

## 生命周期接入

所有模块入口都是主 Actor 隔离的。宿主应创建一个应用级服务并强持有具体模块：

```swift
import ShortcutLauncherCore
import ShortcutLauncherUI

@MainActor
final class LauncherService {
  private(set) var module: ShortcutLauncherModule?

  func start(
    configurationDirectory: URL,
    preferencesDirectory: URL,
    automaticIconCacheDirectory: URL,
    customIconDirectory: URL,
    theme: LauncherTheme = .standard
  ) async throws {
    guard module == nil else { return }

    let iconService = WebsiteIconService(
      cacheDirectoryURL: automaticIconCacheDirectory,
      customIconsDirectoryURL: customIconDirectory
    )
    let instance = ShortcutLauncherModule(
      hostConfiguration: ShortcutLauncherHostConfiguration(
        storageDirectory: configurationDirectory,
        bookmarkPolicy: .securityScopedWhenAvailable
      ),
      uiConfiguration: ShortcutLauncherUIConfiguration(
        theme: theme,
        preferencesStore: LauncherUIPreferencesRepository(
          storageDirectory: preferencesDirectory
        ),
        websiteIconProvider: iconService
      )
    )

    module = instance
    do {
      try await instance.start()
    } catch {
      module = nil
      throw error
    }
  }

  func showPanel() {
    module?.presentPanel()
  }

  func hidePanel() {
    module?.dismissPanel()
  }

  func stop() async {
    guard let module else { return }
    await module.stop()
    self.module = nil
  }
}
```

在应用完成启动后调用 `start()`。退出、切换用户配置或销毁服务前先等待 `stop()`；不要只把模块引用设为 `nil`。如果宿主需要异步清理后再退出，应使用自己的终止协调流程等待 `stop()` 完成。

同一进程一次只能有一个使用共享 owner lease 的生产实例。测试多实例时注入独立 fake registrar 和 owner lease，不要并行启动多个真实 Carbon registrar。

## 数据目录

建议由宿主创建并传入以下目录：

| 数据 | 推荐容器 | 可否重建 |
|---|---|---:|
| Core 配置、备份、锁和拒绝副本 | Application Support | 否 |
| UI 偏好及备份 | Application Support | 可部分重建 |
| 自动网站图标缓存 | Caches | 是 |
| 用户选择的自定义网站图标 | Application Support | 否 |

这些目录可以在同一个宿主容器下分开，也可以由 App Group 统一提供。不要依赖 `WebsiteIconService` 的通用默认目录；显式注入目录可以避免多个宿主互相污染数据。

## 宿主公开契约

宿主可以把具体模块收窄为 `ShortcutLauncherControlling`：

```swift
let controller: any ShortcutLauncherControlling = module

try await controller.start()
controller.presentPanel()
let snapshot = controller.snapshot
controller.dismissPanel()
await controller.stop()
```

`LauncherRuntimeSnapshot` 提供生命周期、配置 revision、面板热键、直接热键暂停状态、38 个槽位摘要和稳定 issue code。它不包含 `LaunchTarget`、完整 URL、bookmark、配置目录或 Carbon 句柄。

快照中的 host-facing `BindingID` 可以直接传给：

```swift
let execution = await controller.executeWithResult(
  bindingID: bindingID,
  source: .panelClick
)
let retry = await controller.retryDirectHotkey(bindingID: bindingID)
```

结果均使用稳定枚举，不要求宿主解析本地化错误文本。

## 程序化配置提交

`commit(_:)` 是乐观并发、全配置候选事务。它会验证 schema、目标和快捷键，准备系统注册，持久化，并在失败时尝试恢复旧注册与旧配置。

```swift
var candidate = module.currentConfiguration
candidate.directModeEnabled = true

let result = await module.commit(
  LauncherCommitRequest(
    expectedConfigurationRevision: module.snapshot.configurationRevision,
    candidateConfiguration: candidate
  )
)

switch result {
case .committed(let revision, let enabled):
  print("revision=\(revision), enabled=\(enabled.count)")
case .validationFailed(let issues):
  print("invalid: \(issues.map(\.code))")
case .registrationFailed(_, let combination):
  print("unavailable: \(combination.displayName)")
case .persistenceFailed(let code):
  print("storage failure: \(code.rawValue)")
case .rejected(let reason):
  print("not committed: \(reason.rawValue)")
}
```

候选必须基于最新已提交配置。收到 `.staleRevision` 时重新读取 revision 和基础配置，再由调用方重新应用意图；不要自动重放一个旧的完整候选。

一般用户编辑优先使用模块自带面板。只有可信任、明确拥有完整配置的宿主才应直接使用 `currentConfiguration` 和 `commit(_:)`；不要从磁盘读 JSON 后绕过事务写回。

## 依赖注入

`ShortcutLauncherUIConfiguration` 支持注入：

- `LauncherTheme`
- `LauncherUIPreferencesStoring`
- `InstalledApplicationCataloging`
- `WebsiteIconProviding`
- `WebsiteIconImagePickerPresenting`

低层初始化器还允许注入 repository、Carbon registrar、bookmark resolver、target opener、panel presenter、target picker、event sink 和 diagnostics sink。生产宿主通常应优先使用 `init(hostConfiguration:uiConfiguration:)`；低层初始化器主要用于特殊宿主和确定性测试。

自定义主题示例：

```swift
let theme = LauncherTheme(
  title: "工作台",
  subtitle: "快速打开常用目标",
  lockedAppearance: nil,
  panelPadding: 28,
  cornerRadius: 20
)
```

设置 `lockedAppearance` 后由宿主锁定外观；为 `nil` 时用户可选择跟随宿主/系统、浅色或深色。

## Sandbox 与权限

- 本模块不需要辅助功能、输入监控、录屏、完全磁盘访问或通知权限。
- Carbon 全局快捷键不依赖 Event Tap。
- Sandbox 宿主使用在线网站图标时需要 outgoing network client entitlement。
- 文件、文件夹和应用选择默认使用 security-scoped bookmark。最终可访问范围仍由宿主签名、Sandbox entitlement 和用户选择决定。
- 如果宿主不能或不应持久化 security-scoped bookmark，可选择 `.lastKnownURLOnly`，但重启后的 Sandbox 访问能力可能降低。

## 集成验证

先运行：

```bash
swift test
swift build
swift build -c release
swift run ShortcutLauncherIntegrationFixture --smoke
```

再在目标宿主真机验证：启动/停止、默认面板热键、直接热键冲突、应用/文件/文件夹/网站、取消系统选择器、拖放、重启恢复、输入法、VoiceOver、深浅色和 Sandbox。测试必须使用独立目录，不能覆盖真实用户配置。
