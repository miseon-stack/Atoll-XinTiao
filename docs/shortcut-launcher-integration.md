# ShortcutLauncher integration

Atoll × 薪跳 embeds ShortcutLauncher 0.6.0 as the local Swift package at `Vendor/ShortcutLauncher`. The app target links only `ShortcutLauncherCore` and `ShortcutLauncherUI`; the package's HostDemo and integration fixture are verification products and are not embedded or published as a second application.

The integrated ShortcutLauncher source and its Atoll host integration are Copyright (C) 2026 miseon-stack and are distributed with [miseon-stack/Atoll-XinTiao](https://github.com/miseon-stack/Atoll-XinTiao) under GNU GPL v3.0. See the repository's `LICENSE` and `NOTICE` files for the applicable terms and upstream attribution.

## Host boundary

`AtollShortcutLauncherService` is the only application-level owner of `ShortcutLauncherModule`. It creates the module on the main actor after Atoll's built-in global shortcuts are registered, presents it from host entry points, and awaits `stop()` during application termination before releasing the module. Real startup is disabled under unit tests and XCUITest so automated tests cannot register global hotkeys or touch user launcher data.

The host entry points are:

- the keyboard-shaped **Launcher** button in the expanded notch header;
- the **Launcher** tile in the expanded notch extras menu;
- **Quick Launcher** in the menu-bar menu;
- **Settings → Shortcuts → Quick Launcher**;
- the module-owned global panel shortcut, initially Control + Option + Q.

## Host-owned data

- Core configuration: `~/Library/Application Support/Atoll/ShortcutLauncher/Core`
- UI preferences: `~/Library/Application Support/Atoll/ShortcutLauncher/UI`
- Custom website icons: `~/Library/Application Support/Atoll/ShortcutLauncher/WebsiteIcons-Custom-v1`
- Automatic website-icon cache: `~/Library/Caches/Atoll/ShortcutLauncher/WebsiteIcons-Automatic-v1`

Atoll currently has App Sandbox disabled. The module still stores local targets as security-scoped bookmarks when available, so its persisted format remains compatible with a future sandboxed host. Automatic favicon fetching uses Atoll's existing network access and requires no additional entitlement in the current non-sandboxed target.

## Distribution boundary

The public repository currently distributes source code only. It does not provide a miseon-stack-signed and Apple-notarized Atoll app or DMG. Developers should build the `main` branch with Xcode 16 or later and a Swift 6 toolchain, using their own signing identity. Bundled media assets are committed as ordinary Git files, so a normal clone or source archive is complete without Git LFS.

Security issues affecting the host integration or ShortcutLauncher should be reported through the repository's [private vulnerability reporting form](https://github.com/miseon-stack/Atoll-XinTiao/security/advisories/new), not a public issue.

## Upgrade procedure

1. Back up the current `Vendor/ShortcutLauncher` directory. Preserve the four Atoll-owned user-data directories through normal backups, but never use or mutate real user data as an upgrade test fixture.
2. Replace `Vendor/ShortcutLauncher` as a whole with the new validated delivery. Do not copy individual source files into Atoll.
3. Read the new `API_STABILITY.md`, integration notes, schema compatibility notes, and changelog. Adapt only the host service if the stable public contract changed.
4. Keep the Atoll-owned directories unchanged. Never edit `launcher-config.json` directly or bypass the module's transactional commit API.
5. Run the package's `./scripts/verify-delivery.sh`, then Atoll Debug and Release builds and the Atoll unit/UI test suites. Confirm the bundled media files are real assets rather than text pointer stubs before packaging either build.
6. Manually verify the panel shortcut, all four target kinds, restart recovery, drag/drop, conflicts, import/export, light/dark appearance, input methods, and VoiceOver before release.
