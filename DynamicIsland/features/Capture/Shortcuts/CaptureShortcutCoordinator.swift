/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Defaults
import Foundation
import KeyboardShortcuts

enum CaptureShortcutAction: Equatable, Sendable {
    case areaScreenshot
    case windowScreenshot
    case fullScreenshot
    case areaRecording
    case fullRecording
    case toggleRecording
    case stopRecording
}

@MainActor
final class CaptureShortcutCoordinator {
    static let shared = CaptureShortcutCoordinator()

    func handle(_ action: CaptureShortcutAction) {
        guard Defaults[.enableShortcuts], isEffective(action) else { return }
        Task {
            switch action {
            case .areaScreenshot: await CaptureActionCoordinator.shared.screenshot(.area)
            case .windowScreenshot: await CaptureActionCoordinator.shared.screenshot(.window)
            case .fullScreenshot: await CaptureActionCoordinator.shared.screenshot(.fullScreen)
            case .areaRecording: await CaptureActionCoordinator.shared.startRecording(.area)
            case .fullRecording: await CaptureActionCoordinator.shared.startRecording(.fullScreen)
            case .toggleRecording:
                if case .preparing = AtollRecordingCoordinator.shared.state {
                    AtollRecordingCoordinator.shared.cancelPreparation()
                } else if AtollRecordingCoordinator.shared.isBusy {
                    await CaptureActionCoordinator.shared.stopRecording(reason: .shortcut)
                } else {
                    await CaptureActionCoordinator.shared.startRecording(.fullScreen)
                }
            case .stopRecording:
                await CaptureActionCoordinator.shared.stopRecording(reason: .shortcut)
            }
        }
    }

    private func isEffective(_ action: CaptureShortcutAction) -> Bool {
        let ordered: [(CaptureShortcutAction, KeyboardShortcuts.Name)] = [
            (.areaScreenshot, .captureAreaScreenshot),
            (.windowScreenshot, .captureWindowScreenshot),
            (.fullScreenshot, .captureFullScreenshot),
            (.areaRecording, .startAreaRecording),
            (.fullRecording, .startFullRecording),
            (.toggleRecording, .toggleAtollRecording),
            (.stopRecording, .stopAtollRecording)
        ]
        guard let current = ordered.first(where: { $0.0 == action }),
              let shortcut = KeyboardShortcuts.getShortcut(for: current.1) else { return false }
        return ordered.first { KeyboardShortcuts.getShortcut(for: $0.1) == shortcut }?.0 == action
    }
}
