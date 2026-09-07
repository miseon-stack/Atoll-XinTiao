# 架构说明

## 分层

```text
Embedding Host
  ├─ owns lifecycle, storage containers, sandbox and product chrome
  └─ ShortcutLauncherControlling / ShortcutLauncherModule
       ├─ ShortcutLauncherUI
       │    ├─ SwiftUI panel and editing flows
       │    ├─ AppKit presentation, pickers and target opening
       │    ├─ Carbon hotkey registrar
       │    ├─ installed-application catalog
       │    └─ website-icon pipeline
       └─ ShortcutLauncherCore
            ├─ models and schema validation
            ├─ revision-aware configuration transaction
            ├─ persistence, backup, locking and migration
            ├─ runtime-state projection
            └─ public host contracts
```

Core 不依赖 UI target。UI 依赖 Core，并在 macOS 上把抽象协议连接到 Carbon、AppKit、SwiftUI、NSWorkspace 和 URLSession。

## 主要组件

### `ShortcutLauncherModule`

模块是 `@MainActor` 的协调器，拥有当前配置、生命周期、已注册热键集合、编辑会话、面板、反馈、搜索目录及网站图标协作。宿主应把它当作一个应用级长生命周期对象，而不是临时 View model。

`ShortcutLauncherControlling` 是较窄的第二宿主契约，包含：

- `start()` / `stop()`
- `presentPanel()` / `dismissPanel()`
- revision-aware `commit(_:)`
- `retryDirectHotkey(bindingID:)`
- `executeWithResult(bindingID:source:)`
- privacy-reduced `snapshot`

### 配置与持久化

`LauncherConfiguration` 当前为 schema v3，保存面板热键、全局直接热键开关及按物理 keyCode 索引的绑定。`ConfigurationRepository` 是 actor，串行执行读取、保存、恢复、导出和导入准备。

文件后端提供：

- 配置验证后写入；
- 同目录临时文件、`fsync` 和原子替换；
- 进程间文件锁；
- 最近有效备份；
- 损坏主配置隔离和备份恢复；
- v1/v2 到 v3 的兼容迁移；
- future schema 拒绝，避免旧版本破坏新数据。

UI 偏好使用独立 schema v1 和独立 repository，不进入 Core 配置导出。

### 快捷键生命周期

`CarbonHotkeyRegistrar` 使用 Carbon `RegisterEventHotKey`，不安装全局 Event Tap。路由表为每次投递冻结 system ID、generation 和 route revision，防止排队中的旧事件在配置切换或停止后被解释成新绑定。

进程级 `HotkeyOwnerLease.processShared` 保证同一进程只有一个生产模块拥有真实全局热键。`stop()` 会注销全部注册并使旧回调失效。

### 配置提交事务

```text
完整候选 + expected revision
        │
        ▼
revision / lifecycle / busy 检查
        │
        ▼
schema、目标、重复组合验证
        │
        ▼
准备新的系统热键注册
        │
        ▼
持久化候选配置
        │
        ▼
提交路由并发布新 revision
```

任一步失败都会保留或补偿恢复最近已提交状态。公开结果只暴露稳定 code、BindingID 和快捷键组合，不暴露 OSStatus、路径、URL 或平台句柄。少数恢复不完整情况会通过 `LauncherPersistenceFailureCode` 和 runtime issue code 明确报告，宿主不应把失败描述为成功。

### 目标执行

支持四类 `LaunchTargetKind`：application、file、folder、web。

- 本地目标优先解析 bookmark，并在 stale 时更新引用。
- 网站只接受 HTTP(S)。
- 执行时冻结已提交记录和 configuration revision，避免异步打开过程中被后续编辑重新解释。
- 面板点击、面板键盘和直接热键使用 `TriggerSource` 区分。

### 面板输入

38 个槽位以物理 keyCode 为身份，显示字符由当前键盘布局快照提供。`PanelInputPolicy` 只允许面板处于合适上下文时把无修饰键的普通按键解释为槽位操作；文本输入、输入法组合、系统快捷键、长按 repeat 和录制器会被隔离。

`ReleaseGate` 要求唤出面板时按住的主键与修饰键都释放后才允许键盘槽位操作，避免唤出组合残留触发绑定。

### 应用搜索

`InstalledApplicationCatalog` 是 actor。默认扫描系统与用户 Applications 目录，把 `.app` 当作终止节点，缓存应用描述，并使用 Core 的搜索 ranking 支持名称、别名和 bundle identifier。宿主可以注入固定目录或自己的索引服务。

### 网站图标

`WebsiteIconService` 是 actor，实现 `WebsiteIconProviding`、更新流和管理能力。优先级为：

```text
custom icon → memory/disk cache → controlled network fetch → deterministic fallback
```

被动展示只读缓存；新绑定、用户刷新或显式补齐才可触发网络。自动缓存与自定义资产分离。网络或解码失败只回退占位图，不影响绑定和执行。

## 并发模型

- `ShortcutLauncherModule`、AppKit presenter 和 picker：MainActor。
- `ConfigurationRepository`、`LauncherUIPreferencesRepository`：actor 串行文件操作。
- `InstalledApplicationCatalog`、`WebsiteIconService`：actor。
- Carbon C callback 通过线程安全路由表捕获，再切回 MainActor 投递。
- 对外数据结构采用 `Sendable` 的不可变快照或值类型。

宿主不应绕过这些边界在后台线程直接驱动 SwiftUI/AppKit，也不应在 event sink 中执行阻塞工作。

## 扩展原则

- 品牌变化通过 `LauncherTheme`，不修改 Core schema。
- 数据容器通过 repository 和 URL 注入，不硬编码宿主 bundle identifier。
- 目录、目标打开、图标和 picker 通过协议替换。
- 新的持久化字段必须有 schema 迁移、future-version 拒绝和 round-trip 测试。
- 新的公开事件不得包含目标 URL、路径、bookmark、查询内容或原始系统错误。
