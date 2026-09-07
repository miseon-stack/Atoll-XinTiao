# API stability policy

ShortcutLauncher is currently pre-1.0. Version 0.6.x preserves the reviewed host integration path but does not promise binary ABI stability.

## Supported integration surface

Embedding applications should build around these APIs:

- `ShortcutLauncherControlling`
- `ShortcutLauncherModule.init(hostConfiguration:uiConfiguration:)`
- `ShortcutLauncherHostConfiguration`
- `ShortcutLauncherUIConfiguration`
- `LauncherRuntimeSnapshot` and `BindingRuntimeSummary`
- `LauncherCommitRequest` and `LauncherCommitResult`
- `HotkeyRetryResult` and `ExecutionResult`
- `LauncherEventSink` and `LauncherDiagnosticsSink`
- documented UI injection protocols used by `ShortcutLauncherUIConfiguration`

The supported behavior is lifecycle control, panel presentation, privacy-safe state observation, revision-aware configuration commits, direct-hotkey retry, and structured execution results.

## Not a compatibility commitment

Other public declarations exist in 0.6.0 for the reference host and deterministic tests. Unless they are listed above or documented in the integration guide, treat them as implementation details that may be hidden in a future minor release.

In particular, do not couple a host to the SwiftUI view hierarchy, popover state, reducer state, repository implementation, Carbon routing internals, favicon parser/loader/cache internals, or HostDemo lifecycle.

## Versioning before 1.0

- Compatible fixes use `0.6.1`, `0.6.2`, and so on.
- New capabilities or breaking API/behavior changes use the next minor version, such as `0.7.0`.
- When practical, an API is deprecated for one minor before removal.
- Raising the minimum macOS or Swift version is a breaking change.
- Changes to `async`, `throws`, actor isolation, `Sendable`, protocol requirements, or exhaustive enum cases are reviewed as breaking changes.

Swift Package consumers should pin an audited commit for tightly controlled products or use `.upToNextMinor(from: "0.6.0")` after a public tag exists.

## Data compatibility

Package versions and persisted schema versions are independent.

- Core configuration is currently schema v3.
- UI preferences are currently schema v1.
- Configuration export envelope is currently v1.

Future releases must continue reading documented historical schemas, reject unknown future schemas without overwriting them, and preserve fixed migration fixtures. A source-compatible release may still require a persisted-schema migration review.
