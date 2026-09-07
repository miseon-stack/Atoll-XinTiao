# 故障排查

## 模块启动失败

### `moduleAlreadyActive`

同一进程已有一个生产模块持有共享 hotkey owner lease。

检查：

1. 宿主是否在多个 Scene、Window 或依赖容器中重复创建模块。
2. 旧实例是否在释放引用前等待了 `stop()`。
3. 测试是否并行启动了多个真实 registrar。

修复方式是把模块提升为应用级单例服务并正确停止旧实例，不要忽略错误后再创建更多实例。

### 配置读失败

检查宿主提供的 Application Support 目录是否可创建和写入。repository 会先尝试主配置，再尝试最近有效 backup；损坏主配置会保存在 `rejected/`。不要手工删除所有文件作为第一步。

如果错误是 `unsupportedFutureSchema`，说明数据由更新版本写入。使用兼容的新版本打开，不要让旧版本覆盖或“修复”该文件。

### 面板快捷键无法注册

默认面板热键或用户设置的组合可能被系统、其他应用或宿主自身占用。退出占用方或让用户选择新组合。不要通过辅助功能权限规避 Carbon 注册冲突。

## 面板没有显示

- 确认已经等待 `start()` 成功后再调用 `presentPanel()`。
- 确认宿主持有 `ShortcutLauncherModule`，而不是只在局部变量中创建。
- 所有调用都应在 MainActor。
- 检查是否立即调用了 `dismissPanel()` 或 `stop()`。
- 多显示器环境下先用菜单动作调用 `presentPanel()`；默认 presenter 会在指针所在屏幕的可见区域内定位。

面板会在应用失去激活时隐藏，这是默认 presenter 的行为。需要不同窗口策略时注入自己的 `LauncherPanelPresenting`，不要修改 Core。

## 直接快捷键不工作

先读取 `snapshot`：

- `directHotkeysPaused == true`：配置的直接模式处于关闭状态。
- `issueCodes` 包含 `directHotkeyConflict`：一个或多个组合未能注册。
- 对应 slot 的 runtime state 显示冲突：使用 host-facing BindingID 调用 `retryDirectHotkey(bindingID:)`，或让用户更换组合/设为仅面板。

`LauncherCommitResult.committed` 的 `enabled` 列表才是本次实际启用的直接绑定，不要仅根据配置存在 `directHotkey` 推断系统注册成功。

## 提交被拒绝

- `.staleRevision`：候选基于旧状态。重新读取最新配置和 `snapshot.configurationRevision`，重新应用用户意图后再提交。
- `.transactionInProgress`：编辑、保存或快捷键录制正在进行，等待当前操作完成。
- `.moduleStopping` / `.moduleUnavailable`：生命周期正在切换或模块未运行。
- `.noChanges`：候选与当前提交状态相同。

`commit(_:)` 是完整配置事务，不是 patch。不要对 `.staleRevision` 自动重复发送同一个候选。

## 配置保存或恢复失败

检查目录写权限、剩余磁盘空间、App Group entitlement 和文件系统是否允许原子 rename/fsync。公开结果可能是：

- `readFailed`
- `writeFailed`
- `recoveryIncomplete`
- `rollbackFailed`

后两种需要明确提示用户：内存、磁盘或系统注册的补偿可能不完整。先 `stop()`，修复存储问题，再重新 `start()` 并核对配置；不要把失败状态宣称为已保存。

## 本地目标打不开

- 文件、文件夹或应用可能已移动、删除，或 bookmark 已失效。
- Sandbox entitlement、签名身份或 App Group 变化会影响旧 bookmark。
- 通过模块的修复入口让用户重新选择目标；不要根据旧字符串路径静默扩大权限。
- 使用 `.lastKnownURLOnly` 的宿主必须接受重启后 Sandbox 访问能力降低的结果。

`ExecutionResult.targetUnavailable` 与 `.failed(..., .targetResolutionFailed)` 用于区分可修复目标和一般执行失败。支持材料中不要附上真实路径或 bookmark。

## 网站图标一直是占位图

这不会影响网站绑定或打开。依次检查：

1. UI 偏好中的在线网站图标是否开启。
2. Sandbox 是否包含 outgoing network client entitlement。
3. 请求 reason 是否允许联网；`.passiveDisplay` 只读缓存。
4. 网站是否提供可接受的 favicon、MIME type 和公网安全跳转。
5. 是否命中 6 小时失败负缓存；用户可显式刷新或清理自动缓存。
6. 自定义图标是否因格式、字节数或像素尺寸被拒绝。

服务拒绝带凭据 URL、HTTPS 降级、过多跳转、超限响应、非图片内容及公网到私网的跳转。这些拒绝不应通过关闭安全检查来修复。

## 搜索不到应用

默认 catalog 扫描系统和用户 Applications 目录，结果有缓存。

- 应用刚安装或移动后调用 `InstalledApplicationCatalog.invalidate()`，再预热或搜索。
- Sandbox 或企业策略可能限制目录枚举；注入宿主自己的 `InstalledApplicationCataloging`。
- `.app` 内部 helper 和 plug-in 不会被索引，这是预期行为。

## 键盘操作异常

- 唤出面板后先释放主键和所有唤出修饰键；`ReleaseGate` 在释放前有意忽略槽位键盘输入。
- 文本框、输入法候选、快捷键录制器和附着 sheet 会接管按键，不应触发底层槽位。
- 长按 repeat 和带 Command/Option/Control/Shift 的系统组合不会当作普通槽位操作。
- 键帽身份按物理 keyCode 保持不变，键盘布局变化只更新显示字符。

若鼠标可用但键盘不可用，先检查焦点和输入法状态，不要添加全局 Event Tap。

## 测试或构建问题

最低要求为 macOS 14、Swift 6、Xcode 16。依次运行：

```bash
swift test
swift build -c release
swift run ShortcutLauncherIntegrationFixture --smoke
```

若 HostDemo bundle 验证失败，重新运行 `./scripts/build-host-app.sh debug`，再检查 Info.plist 和 ad-hoc codesign 输出。XCUITest 不属于默认验证门；测试 bundle 能编译不代表 Runner 已执行成功。

报告问题时提供最小复现、系统/Xcode 版本、稳定 result/issue code、是否使用 Sandbox 和是否使用自定义注入。不要附配置 JSON、bookmark、真实文件路径、完整网站 URL、缓存目录或私有日志。
