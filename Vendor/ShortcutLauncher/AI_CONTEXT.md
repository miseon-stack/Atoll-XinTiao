# ShortcutLauncher AI 接入上下文

本文用于把本仓库交给另一个代码 Agent。它描述的是当前公开接口和必须保持的行为边界，不授权 Agent 复制宿主示例的产品身份、目录或菜单结构。

## 目标

把 `ShortcutLauncherCore` 和 `ShortcutLauncherUI` 作为本地或远程 Swift Package 接入一个 macOS 宿主。宿主负责生命周期、数据目录、Sandbox 权限和产品级 UI；模块负责 38 个物理键位、配置事务、全局快捷键、目标打开、面板、搜索、拖放及网站图标。

运行要求：macOS 14 及以上、Swift 6、Xcode 16 及以上。

## 首先读取

按顺序读取以下文件，再审计目标宿主：

1. `Package.swift`
2. `API_STABILITY.md`
3. `Sources/ShortcutLauncherCore/LauncherHostContract.swift`
4. `Sources/ShortcutLauncherCore/Protocols.swift` 中的 `ShortcutLauncherHostConfiguration`
5. `Sources/ShortcutLauncherUI/WebsiteIconIntegration.swift` 中的 `ShortcutLauncherUIConfiguration`
6. `Sources/ShortcutLauncherUI/ShortcutLauncherModule.swift` 的公开初始化器与生命周期方法
7. `IntegrationFixture/main.swift`
8. `docs/integration.md`、`docs/privacy.md` 和 `docs/configuration-format.md`

`HostDemo` 是参考宿主，不是必须复制的框架。`IntegrationFixture` 才是最小的第二宿主契约验证。

## 不可破坏的约束

- `ShortcutLauncherModule` 是 `@MainActor` 类型，必须在主 Actor 创建和调用。
- 宿主必须强持有模块，从 `start()` 成功后一直保留到 `stop()` 完成。
- 同一进程一次只能有一个生产模块持有全局热键；重复实例会得到 `LauncherError.moduleAlreadyActive`。
- 在释放模块、切换账户或退出进程前等待 `stop()` 完成。`stop()` 会注销热键、关闭面板、取消索引和图标任务并释放进程级 owner lease。
- 不直接改写 `launcher-config.json`。配置修改通过 revision-aware 的 `commit(_:)` 或模块自带编辑流程完成。
- `commit(_:)` 接收完整配置候选，不是局部 patch；必须使用最新 `snapshot.configurationRevision`。遇到 `.staleRevision` 时重新读取状态并由用户或宿主重新生成候选，不能盲目覆盖。
- 本地文件、文件夹和应用使用 security-scoped bookmark 时，配置和导出文件会包含路径及 bookmark 数据，必须视为敏感数据。
- 配置、UI 偏好、自动 favicon 缓存和自定义图标是四个不同的数据边界。宿主应分别注入 Application Support 与 Caches 下的自有目录。
- 不把 `LauncherRuntimeSnapshot`、稳定 `BindingID` 或事件流自动上传。默认 sink 是 no-op；任何遥测均由宿主另行取得用户同意并承担隐私责任。
- 不安装 Event Tap，也不要为本模块申请辅助功能、输入监控、录屏、完全磁盘访问或通知权限。
- Sandbox 宿主若启用在线网站图标，需要 outgoing network client entitlement。本地目标访问仍需按宿主 Sandbox 策略验证 bookmark。
- 网站图标失败不得阻止绑定保存、目标执行或面板显示。

## 最小实现形态

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
    customIconDirectory: URL
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

  func stop() async {
    guard let module else { return }
    await module.stop()
    self.module = nil
  }
}
```

完整接入示例、程序化提交和结果处理见 `docs/integration.md`。

## Agent 的实施顺序

1. 识别目标宿主的 AppKit/SwiftUI 生命周期、现有全局快捷键服务和数据容器。
2. 确认只有一个组件拥有目标快捷键组合，并决定冲突时的产品文案。
3. 确定四类数据目录，不复用示例宿主的 bundle identifier 或固定路径。
4. 检查 Sandbox、App Group、签名身份和 outgoing network entitlement。
5. 添加两个 library product：`ShortcutLauncherCore`、`ShortcutLauncherUI`。
6. 创建一个主 Actor、强持有的服务对象，接入 `start()`、`presentPanel()`、`dismissPanel()` 和 `stop()`。
7. 如需品牌融合，通过 `LauncherTheme`、偏好仓库、应用目录和网站图标 provider 注入，不 fork Core schema。
8. 运行自动验证，并在真实宿主中验证全局快捷键、重启恢复、文件授权、拖放、输入法、VoiceOver 与深浅色。

## 完成标准

- `swift test` 通过。
- `swift build` 与 `swift build -c release` 通过。
- `swift run ShortcutLauncherIntegrationFixture --smoke` 通过。
- 目标宿主可启动和停止模块，退出后没有残留热键。
- 面板热键、直接热键、四类目标和持久化在目标宿主中通过真机验证。
- 验证过程没有读取或修改真实用户已有的 launcher 数据；测试使用独立临时目录。
- 没有把配置、bookmark、缓存、自定义图标、日志或构建产物提交到版本库。

## 可直接发送给目标项目 Agent 的启动指令

把本源码目录放入目标项目可访问的位置后，向负责集成的 Agent 发送：

```text
请把随附的 ShortcutLauncher 作为当前 macOS 产品的一项可替换功能模块接入，不要重新仿写，也不要把 HostDemo 当作第二个应用一起发布。

先完整阅读 ShortcutLauncher/AI_CONTEXT.md、API_STABILITY.md 和 docs/integration.md，再检查当前宿主的生命周期、Swift/macOS 版本、Sandbox、数据容器和现有全局快捷键服务。优先把源码放在 Vendor/ShortcutLauncher，以本地 Swift Package 依赖 ShortcutLauncherCore 与 ShortcutLauncherUI，并只围绕已声明的稳定宿主接口集成。

保留已经验收的 38 键面板、可修改的 Control+Option+Q 默认唤出键、应用/文件/文件夹/HTTP(S) 网站绑定、直接快捷键、图标、bookmark 和持久化行为。不要新增 Event Tap 或辅助功能/输入监控权限。除非存在实质兼容阻塞，完成审计后直接实施并验证，不要只输出方案。

完成后报告：修改文件、产品入口、生命周期接线、四类数据目录、Sandbox/entitlement 处理、快捷键冲突策略、构建测试结果，以及仍需我在真实宿主中手工验收的项目。
```
