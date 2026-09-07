/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import Combine
import ShortcutLauncherCore
import ShortcutLauncherUI
import SwiftUI

@MainActor
final class AtollShortcutLauncherService: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case unavailable(Failure)

        var title: String {
            switch self {
            case .stopped: return "Not running"
            case .starting: return "Starting…"
            case .running: return "Ready"
            case .stopping: return "Stopping…"
            case .unavailable: return "Unavailable"
            }
        }

        var isTransitioning: Bool {
            self == .starting || self == .stopping
        }
    }

    enum Failure: Equatable {
        case panelShortcutUnavailable
        case incompatibleConfiguration(version: Int)
        case duplicateModule
        case storageUnavailable
        case unknown

        var message: String {
            switch self {
            case .panelShortcutUnavailable:
                return "The Quick Launcher panel shortcut is already used by macOS or another app."
            case .incompatibleConfiguration(let version):
                return "The Quick Launcher data was created by a newer version (schema \(version)) and was left unchanged."
            case .duplicateModule:
                return "Another Quick Launcher module is already active in this Atoll process."
            case .storageUnavailable:
                return "Atoll could not prepare the Quick Launcher data directory. Check disk access and try again."
            case .unknown:
                return "Quick Launcher could not start. You can retry from Atoll Settings."
            }
        }
    }

    static let shared = AtollShortcutLauncherService()

    @Published private(set) var state: State = .stopped

    private var module: ShortcutLauncherModule?
    private var startTask: Task<Bool, Never>?

    private init() {}

    var requiresShutdown: Bool {
        module != nil || startTask != nil || state == .starting || state == .running
    }

    var panelHotkeyDisplayName: String {
        module?.activePanelHotkeyDisplayName ?? "⌃⌥Q"
    }

    @discardableResult
    func start() async -> Bool {
        if module != nil, state == .running {
            return true
        }
        if let startTask {
            return await startTask.value
        }

        let task = Task { @MainActor [weak self] in
            await self?.performStart() ?? false
        }
        startTask = task
        let didStart = await task.value
        startTask = nil
        return didStart
    }

    func presentPanel() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await start() {
                module?.presentPanel()
            } else {
                presentUnavailableAlert()
            }
        }
    }

    func dismissPanel() {
        module?.dismissPanel()
    }

    func stop() async {
        if let startTask {
            _ = await startTask.value
        }
        guard let activeModule = module else {
            state = .stopped
            return
        }

        state = .stopping
        activeModule.dismissPanel()
        await activeModule.stop()
        if module === activeModule {
            module = nil
        }
        state = .stopped
    }

    private func performStart() async -> Bool {
        state = .starting

        let paths: AtollShortcutLauncherPaths
        do {
            paths = try .live()
            try paths.prepare()
        } catch {
            state = .unavailable(.storageUnavailable)
            return false
        }

        let websiteIconService = WebsiteIconService(
            cacheDirectoryURL: paths.automaticWebsiteIconCacheDirectory,
            customIconsDirectoryURL: paths.customWebsiteIconsDirectory
        )
        let uiPreferencesStore = LauncherUIPreferencesRepository(
            storageDirectory: paths.uiPreferencesDirectory
        )
        let theme = LauncherTheme(
            title: "快捷启动",
            subtitle: "选择键位，绑定你想打开的目标",
            panelTint: LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.clear,
                    Color.cyan.opacity(0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        let candidate = ShortcutLauncherModule(
            hostConfiguration: ShortcutLauncherHostConfiguration(
                storageDirectory: paths.coreStorageDirectory,
                bookmarkPolicy: .securityScopedWhenAvailable
            ),
            uiConfiguration: ShortcutLauncherUIConfiguration(
                theme: theme,
                preferencesStore: uiPreferencesStore,
                websiteIconProvider: websiteIconService
            )
        )

        // The module contract requires one strong owner from start through the
        // completion of stop. Assign before awaiting start to satisfy it even
        // if application termination arrives during startup.
        module = candidate
        do {
            try await candidate.start()
            state = .running
            return true
        } catch {
            await candidate.stop()
            if module === candidate {
                module = nil
            }
            state = .unavailable(failure(for: error))
            return false
        }
    }

    private func failure(for error: Error) -> Failure {
        guard let launcherError = error as? LauncherError else { return .unknown }
        switch launcherError {
        case .hotkeyConflict, .hotkeyRegistrationFailed, .hotkeyUnavailable:
            return .panelShortcutUnavailable
        case .unsupportedFutureSchema(let version):
            return .incompatibleConfiguration(version: version)
        case .moduleAlreadyActive:
            return .duplicateModule
        case .configurationReadFailed, .configurationWriteFailed:
            return .storageUnavailable
        default:
            return .unknown
        }
    }

    private func presentUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quick Launcher is unavailable"
        if case .unavailable(let failure) = state {
            alert.informativeText = failure.message
        } else {
            alert.informativeText = Failure.unknown.message
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
