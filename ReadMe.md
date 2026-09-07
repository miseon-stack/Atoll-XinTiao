<p align="center">
  <img src=".github/assets/atoll-logo.png" alt="Atoll logo" width="120">
</p>
<h1 align="center">Atoll × 薪跳</h1>
<p align="center">面向 macOS 刘海屏的效率中心、实时收益与快捷启动工具</p>

本项目把“薪跳”的实时收益能力嵌入 Atoll：刘海静默时显示持续增长的收益数字，悬停展开后仍保留 Atoll 原有能力，并提供收益看板、工作日历、日程与待办、截图录屏、快捷键配置和 ShortcutLauncher 快捷启动面板。

这是面向 **macOS 刘海屏设备** 的融合版本，不是原先的 Windows 薪跳桌面版。所有薪资、工作日和偏好设置默认保存在本机。

> 本项目是 [miseon-stack/Atoll-XinTiao](https://github.com/miseon-stack/Atoll-XinTiao)，基于 [Ebullioscopic/Atoll](https://github.com/Ebullioscopic/Atoll) 修改开发，并在 GNU GPL v3.0 下发布。原项目作者、许可证和第三方致谢均予以保留；完整上游历史可在原仓库查阅。Atoll × 薪跳的项目修改与 ShortcutLauncher 集成版权所有 © 2026 miseon-stack。

## 融合版核心能力

- 刘海静默状态显示自适应字号的实时收益数字，可配置显示颜色。
- Home 页实时收益、当日进度与历史收益记录。
- 工作日历，支持工作日、休息日、请假、临时工作日和自定义时间。
- 为任意日期创建、查看、修改和删除日程及待办事项。
- 区域、窗口、全屏截图，以及区域和全屏录制。
- 截图与录屏快捷键可由用户自行配置。
- ShortcutLauncher 0.6.0 面板，可绑定并快速打开应用、网站、文件和文件夹，支持拖放、图标、导入导出与重启恢复。
- 展开刘海后可点击顶部的 **Launcher** 键盘按钮，也可按 **Control + Option + Q** 在全局打开面板。
- 保留 Atoll 的媒体、系统状态、计时器、剪贴板、终端等原有功能。

## 项目文档

- [融合项目 PRD](docs/Atoll_PRD_zh-CN.md)
- [第一阶段验收清单](docs/%E4%B8%80%E6%9C%9F%E9%AA%8C%E6%94%B6%E6%B8%85%E5%8D%95.md)
- [第二阶段验收清单](docs/%E4%BA%8C%E6%9C%9F%E9%AA%8C%E6%94%B6%E6%B8%85%E5%8D%95.md)
- [ShortcutLauncher 集成与升级说明](docs/shortcut-launcher-integration.md)
- [安全漏洞报告](SECURITY.md)
- [变更记录](CHANGELOG.md)


## Highlights
- Media controls for Apple Music, Spotify, Cider, and more with inline previews.
- Live Activities for media playback, Focus, screen recording, privacy indicators, downloads (beta), and battery/charging.
- Lock screen widgets for media, timers, charging, Bluetooth devices, and weather.
- Lightweight system insight for CPU, GPU, memory, network, and disk usage.
- Productivity tools including timers, clipboard history, color picker, and calendar previews.
- Customization for layouts, animations, hover behavior, and shortcut remapping.

## Other Features
- Gesture controls for opening/closing the notch and media navigation.
- Parallax hover interactions with smooth transitions.
- Lock screen appearance and positioning controls for panels and widgets.

## Requirements

- macOS 14.6 or later (macOS 14+; optimised for macOS 15+).
- MacBook with a notch (14/16‑inch MBP across Apple silicon generations).
- Xcode 16 or later with a Swift 6 toolchain.
- Permissions as needed: Accessibility, Camera, Calendar, Screen Recording, Music.

## Build and Run

The supported source branch is `main`:

```bash
git clone --branch main --single-branch https://github.com/miseon-stack/Atoll-XinTiao.git
cd Atoll-XinTiao
open DynamicIsland.xcodeproj
```

In Xcode 16 or later, select the `DynamicIsland` scheme, choose your own development team for local signing, then build and run. Grant Accessibility, Calendar, Screen Recording, Microphone and other permissions only when the corresponding feature is used.

## Source download and binary status

- Source is available from the repository's **Code** menu and `main` branch. Bundled `.mov` and `.gif` assets are regular Git files, so a normal clone or GitHub source download is complete and Git LFS is not required.
- This repository currently provides source code only. It does **not** provide a miseon-stack-signed and Apple-notarized app, DMG, or other executable binary.
- Build the app locally with Xcode and your own signing identity. Do not treat GitHub's automatically generated source archive as a signed macOS application.

## Quick Start

- Hover near the notch to expand; click to enter controls.
- Click the keyboard-shaped **Launcher** button in the expanded notch header, or press **Control + Option + Q**, to open ShortcutLauncher.
- You can also open it from the Atoll menu-bar menu or **Settings → Shortcuts → Quick Launcher**.
- Use tabs for Media, Stats, Timers, Clipboard, and more.
- Adjust layout, appearance, and shortcuts from Settings.
- Add files to Shelf from Terminal: `open -a Atoll /path/to/file`.

## Settings
- Choose appearance, animation style, and per‑feature toggles.
- Remap global shortcuts and adjust hover behaviour.
- Enable lock screen widgets and select data sources.

## Gesture Controls
- Two-finger swipe down to open the notch when hover-to-open is disabled; swipe up to close.
- Enable horizontal media gestures in **Settings → General → Gesture control** to turn the music pane into a trackpad for previous/next or ±10 second seeks.
- Pick the gesture skip behaviour (track vs ±10s) independently from the skip button configuration so swipes can scrub while buttons change tracks—or vice versa.
- Horizontal swipes trigger the same haptics and button animations you see in the notch, keeping visual feedback consistent with tap interactions.

## Troubleshooting (Basics)
- After granting Accessibility or Screen Recording, quit and relaunch the app.
- If metrics are empty, enable categories in Settings → Stats.
- Media not responding: verify player is active and Music permission is granted.

## License

Atoll × 薪跳 is distributed under the GNU General Public License v3.0. Refer to [LICENSE](LICENSE) for the full terms and [NOTICE](NOTICE) for copyright, upstream, bundled-component, and asset attribution. Project-specific modifications and the integrated ShortcutLauncher are Copyright (C) 2026 miseon-stack.

## Acknowledgments

Atoll builds upon the work of several open-source projects and draws inspiration from innovative macOS applications:

- [**Boring.Notch**](https://github.com/TheBoredTeam/boring.notch) - foundational codebase that provided the initial media player integration, AirDrop surface implementation, file dock functionality, and calendar event display. Major architectural patterns and notch interaction models were adapted from this project.

- [**Alcove**](https://tryalcove.com) - primary inspiration for the Minimalistic Mode interface design and the conceptual framework for lock screen widget integration that informed Atoll's compact layout strategy.

- [**Stats**](https://github.com/exelban/stats) - source implementation for CPU temperature monitoring via SMC (System Management Controller) access, frequency sampling through IOReport bindings, and per-core CPU utilisation tracking. The system metrics collection architecture derives from Stats project readers.

- [**Open Meteo**](https://open-meteo.com) - weather apis for the lock screen widgets

- [**SkyLightWindow**](https://github.com/Lakr233/SkyLightWindow) - window rendering for Lock Screen Widgets

- [**rtaudio**](https://github.com/ZephyrCodesStuff/rtaudio) - Live music visualizer using C++ was adapted from this project

- [**SwiftTerm**](https://github.com/migueldeicaza/SwiftTerm) - Terminal tab implementation in the standard mode was adapted from this project

- [**DynamicNotch**](https://github.com/jackson-storm/DynamicNotch) - thanks DynamicNotch for letting us use their battery huds

- Wick - Thanks Nate for allowing us to replicate the iOS like Timer design for the Lock Screen Widget

- [**OpenUsage**](https://github.com/robinebers/openusage) - LLM Usage Tracking features

- [**OpenRouter**](https://openrouter.ai) - API for getting automated model pricing

## Upstream Contributors

感谢 Atoll 及其上游开源项目的所有贡献者。本仓库保留原项目许可证和版权声明；完整 Git 历史与贡献记录可在上游仓库查阅。

<a href="https://github.com/Ebullioscopic/Atoll/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=Ebullioscopic/Atoll" />
</a>

A heartfelt thanks to [TheBoredTeam](https://github.com/TheBoredTeam) for being supportive and being totally awesome, Atoll would not have been possible without Boring.Notch

---

<p align="center">
  <img src=".github/assets/iosdevcentre.jpeg" alt="iOS Development Centre exterior" width="420">
  <br>
  <sub>Backed by</sub>
  <br>
  <strong>iOS Development Centre</strong>
  <br>
  Powered by Apple and Infosys
  <br>
  SRM Institute of Science and Technology, Chennai, India
</p>

<p align="center">
  <a href="https://buymeacoffee.com/kryoscopic">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" width="200" />
  </a>
</p>

<p align="center">
  Your support helps fund teaching children software development.
</p>
