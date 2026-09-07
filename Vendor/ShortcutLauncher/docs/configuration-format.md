# 配置格式与迁移

本文描述当前持久化契约。应用代码应使用 `ConfigurationRepository` 和 `ShortcutLauncherModule.commit(_:)`，不要手工编辑 JSON。

## Core 配置 schema v3

`LauncherConfiguration.currentSchemaVersion` 当前为 `3`。顶层字段：

| 字段 | 类型 | 含义 |
|---|---|---|
| `schemaVersion` | Int | 持久化 schema，写出时固定为 3 |
| `panelHotkey` | HotkeyDefinition | 打开主面板的全局快捷键 |
| `directModeEnabled` | Bool | 是否尝试注册各绑定的直接快捷键 |
| `bindings` | Object | 以物理 keyCode 的十进制字符串为 key 的绑定记录 |

每个 `BindingRecord` 包含：

| 字段 | 类型 | 含义 |
|---|---|---|
| `id` | String | 稳定绑定身份；移动键位时应保留 |
| `physicalKeyCode` | UInt16 | 必须与外层 `bindings` key 一致 |
| `target` | LaunchTarget | application、file、folder 或 web |
| `directHotkey` | HotkeyDefinition? | `null`/缺失表示仅面板；存在时可注册全局直达 |

`LaunchTarget` 包含 `kind`、非空 `displayName`、`lastKnownURL` 以及可选 `bookmarkData`。本地目标必须使用 file URL；网页目标只允许 HTTP(S) 且必须有 host。

下面是说明结构的示意，不应作为手工配置模板：

```json
{
  "bindings": {
    "12": {
      "directHotkey": {
        "keyCode": 12,
        "modifiers": { "rawValue": 4 }
      },
      "id": "6d9f65eb-7e95-42c6-b7fb-c38589f20b21",
      "physicalKeyCode": 12,
      "target": {
        "displayName": "Example",
        "kind": "web",
        "lastKnownURL": "https://example.com/"
      }
    }
  },
  "directModeEnabled": true,
  "panelHotkey": {
    "keyCode": 12,
    "modifiers": { "rawValue": 6 }
  },
  "schemaVersion": 3
}
```

`ModifierSet.rawValue` 位定义：Command `1`、Option `2`、Control `4`、Shift `8`。有效组合必须至少包含一个修饰键，且不能只使用 Shift。物理主键只能来自 `KeySlotCatalog` 的 38 个槽位。

配置验证还要求：

- BindingID 非空、原始 ID 不重复、host-facing 投影不冲突；
- 每个 binding 的字典 key 与 `physicalKeyCode` 相同；
- 面板快捷键、直接快捷键和目标都有效；
- 直接快捷键彼此不重复，也不能等于面板快捷键；
- schema 必须已经迁移为当前版本。

## 文件布局

`ConfigurationRepository(storageDirectory:)` 在宿主提供的目录中管理：

```text
launcher-config.json                 当前配置
launcher-config.backup.json          最近有效备份
launcher-config.lock                 进程间写锁
configuration-v1.json                仅用于旧版本发现与迁移
rejected/                            无效主配置的保留副本
```

保存前后都会验证配置。写入使用同目录临时文件、文件同步和原子替换；已有有效主配置在覆盖前保存为 backup。恢复补偿会让 primary 和 backup 都回到最近已提交状态。

主配置损坏时，repository 保留拒绝副本并尝试从 backup 恢复。主配置和 backup 均不可用时返回读失败，不会静默重置用户绑定。future schema 会直接拒绝，不会隔离或覆盖。

## 旧 schema 迁移

解码时支持 v1、v2 和 v3：

- 缺失 `schemaVersion` 按 v1 读取。
- v1 可使用单独的 `qBinding`。
- v1/v2 的 `bindings` 是 keyCode 到 `LaunchTarget` 的映射，并可带全局 `directModifiers`。
- 迁移后为每个旧绑定生成 `legacy-v2-<keyCode>` ID，并根据旧修饰键生成 direct hotkey。
- 成功读取旧格式后立即按 v3 重写主配置，并通过 `ConfigurationLoadResult.migrated` 报告。

高于当前版本的 schema 抛出 `LauncherError.unsupportedFutureSchema`，宿主应提示用户使用兼容版本，不得删除或降级该文件。

## 导入与导出

Core 导出不是裸 `LauncherConfiguration`，而是 `ConfigurationExportEnvelope`：

```json
{
  "configuration": { "schemaVersion": 3 },
  "exportVersion": 1,
  "exportedAt": "<ISO-8601 timestamp>"
}
```

实际 `configuration` 包含全部配置字段。当前 `exportVersion` 为 1；导入上限为 5 MiB。`prepareImport(_:)` 只解码、验证并返回 `PreparedConfigurationImport` 和统计预览，不自动覆盖当前配置。调用方仍需用最新 revision 通过模块事务提交候选。

导出内容可能包含文件 URL、完整网站 URL 和 base64 编码 bookmark，必须视为敏感文件。UI 偏好和网站图标不在该导出中。

## UI 偏好 schema v1

`LauncherUIPreferences` 独立于 Core 配置：

```json
{
  "appearance": "system",
  "onlineWebsiteIconsEnabled": true,
  "onboardingVersion": 0,
  "schemaVersion": 1
}
```

对应文件：

```text
launcher-ui-preferences.json
launcher-ui-preferences.backup.json
rejected-ui-preferences/
```

UI 偏好只允许外观、在线图标开关和 onboarding 版本。不要向该类型加入目标、URL、路径、bookmark、目标名称或热键。损坏时可以从 backup 恢复；backup 也损坏时恢复 privacy-safe 默认值。future schema 同样拒绝覆盖。

## Schema 演进规则

修改持久化格式时应同时：

1. 提升对应 `currentSchemaVersion`。
2. 保留旧版本解码与显式迁移。
3. 拒绝 future schema。
4. 新增 round-trip、迁移、损坏恢复和原子写失败测试。
5. 更新导出 envelope 的兼容策略；只有导出容器本身不兼容时才提升 `exportVersion`。
6. 评估新增字段的隐私、日志和 host snapshot 影响。
