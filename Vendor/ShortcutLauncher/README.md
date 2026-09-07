# ShortcutLauncher

[简体中文](README.zh-CN.md)

ShortcutLauncher is a native, local-first macOS feature module that binds 38 physical keyboard slots to applications, files, folders, and HTTP(S) websites.

Version 0.6.0 is designed to be embedded in another macOS app through Swift Package Manager. `ShortcutLauncherHostDemo` is a reference host, not a second app that consumers need to ship.

## What it provides

- A configurable global panel hotkey, defaulting to Control–Option–Q.
- A 38-slot keyboard panel: `1…0`, `-`, `=`, `Q…P`, `A…L`, and `Z…M`.
- Application, file, folder, and HTTP(S) website targets.
- Optional direct global shortcuts for individual bindings.
- Persistent security-scoped bookmarks for local targets.
- Application icons, system file icons, and privacy-bounded website favicon discovery.
- Atomic, revision-aware configuration updates and hotkey conflict recovery.
- Host-injected storage, appearance, event sinks, diagnostics, application catalog, and website icon services.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- Swift 6

## Local package integration

Copy the source package into the host repository, for example:

```text
YourProduct/
└── Vendor/
    └── ShortcutLauncher/
```

Add `Vendor/ShortcutLauncher` as a local Swift package and link the `ShortcutLauncherCore` and `ShortcutLauncherUI` products to the macOS app target.

Create and retain one controller on the main actor:

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

The host must wait for `stop()` before releasing the final module reference. Only one production module in a process may own the global hotkeys.

Read [the integration guide](docs/integration.md) before changing app lifecycle, sandbox, storage, or menu-bar wiring. AI-assisted integrations should start with [AI_CONTEXT.md](AI_CONTEXT.md).

## Verification

The default verification path does not launch the app, request UI-automation access, or contact public websites:

```bash
./scripts/verify-delivery.sh
```

It covers unit/component tests, deterministic favicon fixtures, the public API compile test, a second-host smoke test, Debug and Release builds, HostDemo assembly, plist/version checks, ad-hoc signature verification, and source privacy checks.

Real UI automation remains an explicit trusted-Mac lane because macOS may request automation permissions for the test runner.

## Privacy and permissions

The production module does not install a global event tap and does not require Accessibility, Input Monitoring, Screen Recording, Full Disk Access, notifications, or UI-automation permissions.

Website icon fetching is origin-scoped, uses an ephemeral session, sends no browser cookies or stored page path/query/fragment, and falls back locally when unavailable. See [docs/privacy.md](docs/privacy.md).

## Version and API policy

The package follows semantic versioning while it is below 1.0. Consumers should pin a reviewed commit or use an up-to-next-minor requirement for `0.6.x`. See [API_STABILITY.md](API_STABILITY.md).

## License

ShortcutLauncher is free software licensed under the GNU General Public License, version 3. Copyright (C) 2026 miseon-stack. See [LICENSE](LICENSE) for the complete terms.

## Repository status

The owner decisions for public source publication are complete: the package uses the `io.github.miseon-stack.shortcutlauncher` namespace and is licensed under GPL-3.0. Complete the remaining repository and release operations in [PUBLICATION_CHECKLIST.md](PUBLICATION_CHECKLIST.md) before creating a tagged release. `ShortcutLauncherHostDemo` remains a reference host and must not be distributed as a second production application.

## Documentation

- [Integration](docs/integration.md)
- [Architecture](docs/architecture.md)
- [Privacy](docs/privacy.md)
- [Configuration format](docs/configuration-format.md)
- [Development](docs/development.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Support](SUPPORT.md)
- [Security policy](SECURITY.md)
