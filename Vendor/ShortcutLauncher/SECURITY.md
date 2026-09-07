# Security policy

## Supported versions

Until a public release exists, security fixes are applied to the current `0.6.x` integration line. After publication, this table should be updated for every supported line.

## Reporting a vulnerability

Do not open a public issue for vulnerabilities that could expose user paths, bookmarks, website origins, arbitrary target execution, or hotkey interception.

Report vulnerabilities privately through [GitHub Private Vulnerability Reporting](https://github.com/miseon-stack/Atoll-XinTiao/security/advisories/new). Include the affected version, reproduction steps, impact, and a minimal non-sensitive example. Do not include real launcher configuration files, bookmarks, private URLs, credentials, or other user data.

## Security boundaries

- Launch targets are limited to applications, files, folders, and HTTP(S) websites.
- The module does not execute shell commands or accept arbitrary executable strings.
- Persisted local bookmarks and configuration are private user data.
- Website favicon retrieval must retain the URL, redirect, response-size, MIME, image-dimension, and private-network defenses described in `docs/privacy.md`.
- The default automated test lane must not use real user targets, public network services, or UI-automation permissions.
