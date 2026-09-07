# Contributing

Thank you for improving ShortcutLauncher.

## Before opening a change

1. Use macOS 14 or later, Xcode 16 or later, and Swift 6.
2. Read `docs/architecture.md`, `docs/privacy.md`, and `API_STABILITY.md`.
3. Keep the feature boundary limited to launching applications, files, folders, and HTTP(S) websites.
4. Do not add telemetry, account systems, cloud sync, shell execution, arbitrary URL schemes, or new system permissions without an explicit design and privacy review.

## Development

Create a focused branch, make the smallest coherent change, and add deterministic tests. The default test path must not access public websites, open real user targets, mutate user data, or request macOS UI-automation permissions.

Run:

```bash
./scripts/verify-delivery.sh
```

Pull requests should explain user impact, compatibility impact, persisted-data impact, privacy/permission impact, and manual verification still required.

## Source hygiene

Never commit credentials, personal URLs, local file paths, bookmarks, user configuration, website icon caches, `.build`, DerivedData, `.xcresult`, screenshots containing private information, or AI-agent memory files.

Contributions must be your own work or material you are authorized to submit under the GNU General Public License, version 3, used by this repository.
