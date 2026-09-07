/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation

/// Host-owned storage locations for the embedded ShortcutLauncher module.
/// Keeping these paths outside the vendored package makes future module
/// upgrades replaceable without moving or rewriting user data.
struct AtollShortcutLauncherPaths: Equatable {
    let coreStorageDirectory: URL
    let uiPreferencesDirectory: URL
    let automaticWebsiteIconCacheDirectory: URL
    let customWebsiteIconsDirectory: URL

    init(applicationSupportDirectory: URL, cachesDirectory: URL) {
        let supportRoot = applicationSupportDirectory
            .appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent("ShortcutLauncher", isDirectory: true)
        let cacheRoot = cachesDirectory
            .appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent("ShortcutLauncher", isDirectory: true)

        coreStorageDirectory = supportRoot.appendingPathComponent("Core", isDirectory: true)
        uiPreferencesDirectory = supportRoot.appendingPathComponent("UI", isDirectory: true)
        customWebsiteIconsDirectory = supportRoot.appendingPathComponent(
            "WebsiteIcons-Custom-v1",
            isDirectory: true
        )
        automaticWebsiteIconCacheDirectory = cacheRoot.appendingPathComponent(
            "WebsiteIcons-Automatic-v1",
            isDirectory: true
        )
    }

    static func live(fileManager: FileManager = .default) throws -> Self {
        let applicationSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory
        )
    }

    func prepare(fileManager: FileManager = .default) throws {
        for directory in [
            coreStorageDirectory,
            uiPreferencesDirectory,
            automaticWebsiteIconCacheDirectory,
            customWebsiteIconsDirectory,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
