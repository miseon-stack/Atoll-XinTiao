/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Defaults
import Foundation

struct CapturePreferences: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var screenshotFolderBookmark: Data?
    var recordingFolderBookmark: Data?
    var capturesSystemAudio = true
    var capturesMicrophone = false
    var completionNotificationsEnabled = true
    var excludesAtollFromCapture = true
}

extension CapturePreferences: Defaults.Serializable {}

extension Defaults.Keys {
    static let capturePreferences = Key<CapturePreferences>(
        "capturePreferences.v1",
        default: CapturePreferences()
    )
}
