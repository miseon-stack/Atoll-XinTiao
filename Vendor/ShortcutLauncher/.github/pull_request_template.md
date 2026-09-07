## Summary

Describe the user-visible or integration-facing outcome and why it is needed.

## Scope

- [ ] Bug fix
- [ ] Additive feature
- [ ] Public API or integration change
- [ ] Documentation, tests, or tooling only

## Verification

- [ ] Relevant Swift tests were added or updated.
- [ ] `swift test` passes locally, or the reason it was not run is stated below.
- [ ] `swift run ShortcutLauncherIntegrationFixture --smoke` passes when public integration behavior changes.
- [ ] The required source-delivery CI gate passes.
- [ ] XCUITest or manual desktop testing is claimed only if it was actually performed.

Commands and results:

```text

```

## Compatibility and API

- [ ] macOS 14 minimum deployment compatibility is preserved or the change is documented.
- [ ] Public API changes are additive, or migration and versioning impact is documented.
- [ ] Host lifecycle, storage ownership, Sandbox, bookmark, network, and signing effects were considered where relevant.

## Privacy and repository hygiene

- [ ] Tests use fakes, injected loaders, and temporary storage rather than public-network or real-permission flows.
- [ ] No personal paths, launcher configurations, bookmarks, credentials, caches, custom icons, build products, or Agent state are included.
- [ ] Logs, screenshots, and fixtures are sanitized.

## Documentation

List documentation changes, migration notes, or explain why none are required.
