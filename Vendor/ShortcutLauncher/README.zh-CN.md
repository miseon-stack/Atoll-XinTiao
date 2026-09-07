# ShortcutLauncher 快捷启动模块

[English](README.md)

ShortcutLauncher 是一个原生、离线优先的 macOS 功能模块。它把 38 个物理键位绑定到应用、文件、文件夹或 HTTP(S) 网站，并可以作为另一个 macOS 产品中的一项功能接入。

0.6.0 版本已经完成产品验收。`ShortcutLauncherHostDemo` 只是参考宿主，接入方不需要把它作为第二个应用一起发布。

## 已实现能力

- 默认使用 Control + Option + Q 唤出面板，并允许用户在面板内修改该组合键。
- 固定 38 键：`1～0`、`-`、`=`、`Q～P`、`A～L`、`Z～M`。
- 支持绑定应用、文件、文件夹和 HTTP(S) 网站。
- 支持为单个绑定配置可选的全局直达快捷键。
- 本地目标使用 security-scoped bookmark 持久恢复。
- 显示应用图标、系统文件图标和受隐私边界约束的网站 favicon。
- 配置保存、热键注册、冲突恢复和撤销使用 revision-aware 原子事务。
- 宿主可以注入数据目录、主题、事件与诊断出口、应用目录和网站图标服务。

## 环境要求

- macOS 14 或更高版本
- Xcode 16 或更高版本
- Swift 6

## 推荐接入方式

把源码包放到目标项目中，例如：

```text
你的产品/
└── Vendor/
    └── ShortcutLauncher/
```

在 Xcode 中把 `Vendor/ShortcutLauncher` 添加为本地 Swift Package，并让 macOS App target 依赖 `ShortcutLauncherCore` 与 `ShortcutLauncherUI`。

宿主在主线程创建并持有一个模块实例：

```swift
import ShortcutLauncherCore
import ShortcutLauncherUI

@MainActor
final class LauncherFeature {
  private let controller: any ShortcutLauncherControlling

  init(applicationSupportDirectory: URL) {
    let storageDirectory = applicationSupportDirectory
      .appendingPathComponent("ShortcutLauncher", isDirectory: true)
    controller = ShortcutLauncherModule(
      hostConfiguration: ShortcutLauncherHostConfiguration(
        storageDirectory: storageDirectory,
        bookmarkPolicy: .securityScopedWhenAvailable
      )
    )
  }

  func start() async throws { try await controller.start() }
  func showPanel() { controller.presentPanel() }
  func stop() async { await controller.stop() }
}
```

应用启动后调用 `start()`；需要从菜单或设置入口显示面板时调用 `presentPanel()`；应用退出或卸载功能前必须等待 `stop()` 完成。同一进程只允许一个正式模块持有全局热键。

完整接入步骤见 [docs/integration.md](docs/integration.md)。把模块交给另一个 AI 上下文时，先提供 [AI_CONTEXT.md](AI_CONTEXT.md)，再让它按需读取源码。

## 验证

```bash
./scripts/verify-delivery.sh
```

默认验证不会启动图形应用、不会请求 UI 自动化权限，也不会访问真实公网。它会验证全部单元与组件测试、确定性网站图标 fixture、公开 API 编译、第二宿主、Debug/Release、HostDemo 组装、plist/版本、ad-hoc 签名和源码隐私边界。

## 权限与隐私

正式模块不使用全局 Event Tap，不需要辅助功能、输入监控、录屏、完全磁盘访问、通知或 UI 自动化权限。网站图标请求不携带浏览器 Cookie，也不会发送已绑定网址的 path、query 或 fragment。详见 [docs/privacy.md](docs/privacy.md)。

## 许可证

ShortcutLauncher 是按 GNU 通用公共许可证第 3 版发布的自由软件。Copyright (C) 2026 miseon-stack。完整条款见 [LICENSE](LICENSE)。

## 当前发布状态

公开源码所需的所有者决策已经完成：模块使用 `io.github.miseon-stack.shortcutlauncher` 命名空间，并按 GPL-3.0 发布。创建带版本标签的公开 Release 前，仍须完成 [PUBLICATION_CHECKLIST.md](PUBLICATION_CHECKLIST.md) 中剩余的仓库与发布操作。`ShortcutLauncherHostDemo` 仍然只是参考宿主，不得作为第二个正式应用分发。

## 文档

- [接入手册](docs/integration.md)
- [架构说明](docs/architecture.md)
- [隐私边界](docs/privacy.md)
- [配置格式](docs/configuration-format.md)
- [开发与验证](docs/development.md)
- [故障排查](docs/troubleshooting.md)
- [支持范围](SUPPORT.md)
- [安全策略](SECURITY.md)
