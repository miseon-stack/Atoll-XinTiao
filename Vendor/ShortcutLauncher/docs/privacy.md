# 隐私与安全边界

ShortcutLauncher 默认本地运行，不包含账号、云同步或遥测服务。宿主仍需根据自己的分发方式、数据处理和地区法规提供最终隐私说明。

## 本地数据清单

| 数据 | 典型内容 | 建议位置 | 敏感性 |
|---|---|---|---|
| Core 配置 | 绑定、物理 keyCode、热键、目标 URL、bookmark | Application Support | 高 |
| Core 备份与拒绝副本 | 最近有效配置或损坏原始字节 | Application Support | 高 |
| UI 偏好 | 外观、在线图标开关、首次提示版本 | Application Support | 低 |
| 自动网站图标缓存 | 规范化 origin 的哈希键、PNG、TTL/负缓存 | Caches | 中 |
| 自定义网站图标 | 用户选择的规范化 PNG 与 manifest | Application Support | 中 |
| 应用索引、查询、Toast、Undo | 瞬态内存 | 内存 | 取决于内容 |

Core 配置和导出包可能包含本地文件路径、网站完整 URL 和 security-scoped bookmark。不要把这些文件加入 Git、工单、聊天上下文、崩溃附件或公开日志。

移除某个绑定只删除模块记录，不删除真实目标。清理自动图标缓存不会删除自定义图标。

## 宿主快照与事件

`LauncherRuntimeSnapshot` 有意不包含持久化配置、完整目标、bookmark、配置目录和系统句柄。看起来像路径或 URL 的 display name 会退化为目标类型名称；可能携带资源位置的旧 `BindingID` 会映射为不可逆 SHA-256 别名。

这并不等于允许自动上传快照：

- `BindingID` 仍是稳定的伪标识符；
- 未呈现为路径的用户自定义名称仍可能敏感；
- 热键和使用时间也可能反映用户习惯。

默认 event 和 diagnostics sink 均为 no-op。宿主注入 sink 后，应采用数据最小化、明确目的、用户同意、保留期限和访问控制，不要追加 URL、路径、搜索词、bookmark、原始错误描述或配置正文。

## 网站图标网络行为

在线图标默认可由用户关闭。触发网络时：

- 从绑定 URL 只派生 `scheme + host + 非默认端口`；path、query、fragment 和嵌入凭据不会进入 origin 请求。
- 初始请求访问 origin 根页面，并检查明确声明的 favicon；也可尝试同 origin 的 `/favicon.ico`。
- 使用 ephemeral `URLSession`，禁用 Cookie storage、credential storage、URL cache 和自动凭据。
- 不发送浏览器 Cookie、共享登录态、Authorization 或 Referer，不使用 WebView，不执行 JavaScript。
- 每次跳转重新进行 scheme、origin、DNS/IP 和资源类型校验；HTTPS 不降级到 HTTP。
- 公网站点不能重定向或声明私有、环回、链路本地等非公网目标。显式绑定的本地站点只能访问其完全相同的 origin，不能借重定向横向访问其他本地服务。
- 跨 origin 图标只接受根页面明确声明的 HTTPS 资源。
- 不使用第三方 favicon 聚合服务。

网站或其明确声明的 CDN 仍会看到普通连接所暴露的来源 IP、请求时间和 User-Agent 默认行为。若宿主的隐私承诺不允许该连接，应注入离线 `WebsiteIconProviding`，或把 `onlineWebsiteIconsEnabled` 默认设为关闭。

生产策略限制包括：HTML 256 KiB、最多发现 8 个候选、下载 3 个候选、单图标 1 MiB、3 次重定向、总超时 6 秒、网络并发 3、输入最大 4096×4096、输出最长边 256 px。自动磁盘缓存上限为 20 MiB 或 256 个 origin，成功 TTL 为 7 天，失败负缓存为 6 小时。

自动缓存键是规范化 origin 的 SHA-256，不保存明文完整 URL。哈希不是匿名化：若攻击者已知候选域名，仍可进行枚举比对，所以缓存目录仍应按用户数据保护。

## 系统权限

模块不要求：

- 辅助功能；
- 输入监控；
- 屏幕录制；
- 完全磁盘访问；
- 通知；
- UI 自动化。

Carbon 全局快捷键不使用 Event Tap。测试基础设施可能使用 XCUITest，但那不是产品运行时权限，且不应混入默认自动门。

Sandbox 宿主需要自行配置：

- 在线网站图标所需的 outgoing network client entitlement；
- 用户选择文件所需的 appropriate user-selected file entitlement；
- security-scoped bookmark 的创建、持久化和恢复策略；
- App Group 场景中的容器访问。

权限或签名身份改变后必须重新做真实宿主验证。

## 日志与支持材料

- 公开结果枚举优先于 `localizedDescription`。
- OSLog 中的错误细节必须标记 private，且支持工单中不要要求用户直接上传配置。
- 如需诊断，优先收集 lifecycle state、稳定 issue code、schema 版本和是否发生恢复，不收集目标值。
- 截图、录屏和 UI 测试 fixture 发布前检查是否包含真实应用名、文件名、网址或用户名。

## 删除与迁移

宿主应提供或记录四类数据的删除方式。跨宿主迁移时只传递用户明确导出的 Core 配置；UI 偏好、自动缓存和自定义图标不会自动包含在 Core 导出包中。导出前应提示用户文件包含敏感目标信息，并通过用户选择的位置保存。
