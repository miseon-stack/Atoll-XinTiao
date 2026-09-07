# 开发与验证

## 环境

- macOS 14 及以上
- Swift 6
- Xcode 16 及以上
- zsh（仓库脚本）

工程没有第三方 package 依赖。`Package.swift` 定义两个 library、一个参考宿主 executable、一个第二宿主 smoke executable 和三组测试 target。

## 常用命令

```bash
swift build
swift build -c release
swift test
swift run ShortcutLauncherIntegrationFixture --smoke
./scripts/build-host-app.sh debug
./scripts/build-host-app.sh release
```

通用自动验证入口：

```bash
./scripts/verify.sh
```

该脚本运行 Swift 测试、构建第二宿主 fixture、构建 Debug HostDemo，并检查 Info.plist 与 ad-hoc 签名。发布前还应显式运行上方的 Release 构建和第二宿主 smoke，并执行隐私、运行数据与 `git diff --check` 检查。自动门不应访问公共网站，也不应把 XCUITest Runner 混入无交互验证。

## 测试分层

- `Tests/ShortcutLauncherCoreTests`：模型、输入策略、事务、持久化、迁移、状态和公开契约。
- `Tests/ShortcutLauncherUITests`：模块、Carbon 路由、搜索、拖放、偏好、网站图标和 UI 组件逻辑。
- `Tests/ShortcutLauncherPublicAPITests`：从 package consumer 视角编译受支持的公开接入面。
- `IntegrationFixture`：只通过公开契约及注入边界验证第二宿主。
- `UITestHost`：真实 XCUIApplication 基础设施，不属于默认自动门。

网站图标测试必须使用 URLProtocol、fake loader 和临时目录。公共网站的实时响应不能成为合并或发布判断条件。

运行 XCUITest 前应预期系统测试服务、输入法或文件选择器可能触发权限和环境差异。只在隔离测试用户或明确准备的机器上运行，并如实区分“测试 bundle 编译成功”和“UI 测试实际执行通过”。

## 修改原则

### Core schema

修改 `LauncherConfiguration` 或 `LauncherUIPreferences` 时，按 `configuration-format.md` 的 schema 演进规则增加迁移、future-version 和 round-trip 测试。不要在 UI 偏好中存储 Core 目标数据。

### 公共契约

`ShortcutLauncherControlling`、公开 result enum、event 字段和 snapshot 是宿主兼容边界。新增公开数据前检查：

- 是否可 `Sendable`；
- 是否泄露 URL、路径、bookmark、查询、原始错误或句柄；
- 是否有稳定 code，而不是要求宿主解析中文文本；
- 是否保持旧调用方源码兼容。

### 事务与快捷键

任何配置写入必须继续满足“旧配置、磁盘状态、系统注册和路由含义一致”。不要在持久化候选尚未确定时发布新配置，也不要复用排队中的 Carbon 回调解释新绑定。

新增注册逻辑时覆盖：冲突、部分准备失败、保存失败、回滚失败、停止期间回调、重启恢复和同进程 owner 冲突。

### 文件和网络

- 测试只能使用唯一临时目录，不读写真实用户配置。
- 不把配置、偏好、缓存、自定义图标、`.xcresult` 或日志纳入 fixture。
- 网络解析维持 origin 最小化、逐跳校验、字节/像素/并发/超时限制和无凭据 session。
- 网络和文件 I/O 不进入 MainActor；SwiftUI/AppKit 操作留在 MainActor。

## 提交前检查

```bash
swift test
swift build -c release
swift run ShortcutLauncherIntegrationFixture --smoke
git diff --check
git status --short
```

还应人工确认：

- 没有本机绝对路径、凭据、真实 URL 或用户数据；
- 新文件已被测试或文档索引覆盖；
- README、迁移文档和配置说明与公开 API 一致；
- 不相关的工作树修改没有被覆盖；
- 版本号、构建号和发布说明一致。

## 发布建议

Swift Package 版本由 Git tag 决定，使用 SemVer。发布只能从全绿、干净的提交创建；归档应基于 tag，而不是直接压缩工作目录。源码归档排除 `.git`、`.build`、`.swiftpm`、DerivedData、xcuserdata、日志、运行数据和本地 Agent 状态，并同时生成 SHA-256。

仓库的白名单打包入口为：

```bash
./scripts/package-source.sh ./dist
```

脚本会把公开文件复制到无 Git 历史的临时源码树，在该树中运行 `scripts/verify-delivery.sh`，然后生成 ZIP、源码清单、验证报告和 SHA-256。`verify-delivery.sh` 面向清理后的交付树；直接在包含 `.git` 或本地 Agent 状态的开发工作树运行时会按设计拒绝。

HostDemo 当前使用 ad-hoc 签名用于本地验证。未完成 Developer ID 签名和 Apple 公证前，只发布源码，不把该 `.app` 描述为可直接分发的正式二进制。
