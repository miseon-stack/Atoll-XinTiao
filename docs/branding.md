# Work Tempo 品牌与兼容约定

- 正式产品名称：**Work Tempo**。
- 公开仓库：`miseon-stack/work-tempo`。
- 正式图标：用户于 2026-09-08 确认的 5 号原图，位于 `.github/assets/work-tempo-icon.png`。
- 原图 SHA-256：`e0e411fd2c63e286465c64668428744ef641200715de5a8cb9393a2ca0e41aaf`。
- 不自行重新生成图案或改变配色。资源尺寸可通过 `node scripts/update-brand-icons.mjs` 在 macOS 上重新生成；该脚本先验证原图，再用系统工具缩放。

## 展示范围

应用显示名与可执行文件为 Work Tempo，应用包为 `Work Tempo.app`。欢迎页、关于页、设置窗口、菜单栏、更新提示、权限用途说明、应用图标以及 README 使用同一品牌。Debug、Release 和渠道备用图标都使用同一确认稿；渠道信息仍由更新渠道标签显示。

## 保留的兼容身份

以下名称不是产品展示名，本次不迁移：

- Debug Bundle ID：`com.Ebullioscopic.Atoll.dev`；Release：`com.Ebullioscopic.Atoll`。
- Swift module `Atoll`、Xcode 项目与 scheme `DynamicIsland`，以及 AtollExtensionKit 对外协议。
- UserDefaults、Keychain、URL scheme、日程来源标记、全局快捷键标识、文件访问书签。
- `Application Support/Atoll`、`Caches/Atoll`、原有截图和录屏目录，以及 Apple Notes 的 `Atoll` 同步文件夹。
- Sparkle 既有公私钥配对和 Keychain 账户不变；只更新公开仓库和 feed URL。

这样更名不会因切换身份而读取到空配置，也不会创建第二套收益、快捷启动或备忘录数据。不要把内部 Atoll 字样机械替换为 Work Tempo；未来若需要迁移，必须另行设计备份和恢复。

本次保留 GPL 许可证、源文件版权头与第三方来源说明。品牌独立不意味着第三方代码成为原创。

## 验证

运行 `python3 -m unittest discover -s tests -p 'test_*.py'` 检查品牌、图标尺寸、更新源与数据兼容约定，再构建和测试 `DynamicIsland` scheme。本机验收应使用与既有数据一致的 Debug Bundle ID，不因更名切换到 Release 身份。
