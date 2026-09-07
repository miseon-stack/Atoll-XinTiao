# First-publication checklist

The owner decisions for GPL-3.0 public source publication are complete. Finish every remaining unchecked repository and release operation before publishing a GitHub release.

## Owner decisions

- [x] License selected: GNU General Public License, version 3; see `LICENSE`.
- [x] Legal copyright holder and year recorded: Copyright (C) 2026 miseon-stack.
- [x] Owner-controlled reverse-DNS namespace selected: `io.github.miseon-stack.shortcutlauncher`.
- [x] Replaced legacy private placeholder identifiers in the reference host, UI-test host, log subsystems, and exported UTTypes.
- [x] Selected GitHub Private Vulnerability Reporting as the private security route; see `SECURITY.md`.

## Repository preparation

- [ ] Initialize a new clean public repository from the generated `*-public-source` directory. Do not push the private development history.
- [ ] Confirm the source manifest contains no Agent memory, old internal PRDs, competitor material, private paths, runtime data, build output, caches, or user configuration.
- [x] Add the selected `LICENSE` file and update README/repository metadata.
- [ ] Set Actions workflow permissions to read-only by default.
- [ ] Protect `main`; require the build-and-test check before merge.
- [ ] Require approval for untrusted fork workflows where appropriate; do not send secrets or write tokens to fork pull requests.
- [ ] Enable GitHub Private Vulnerability Reporting in the public repository settings and verify the documented route.

## Release

- [ ] Review the public API and configuration schema fixtures.
- [ ] Run `./scripts/verify-delivery.sh` from a clean archive with no `.git` directory.
- [ ] Confirm `CFBundleShortVersionString`, build number, changelog, and tag agree.
- [ ] Create an annotated `v0.6.0` tag in the new public repository.
- [ ] Generate the source archive and checksums from that tag.
- [ ] Publish source only. Do not publish an unsigned/unnotarized `.app` as a production download.
