/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import CoreGraphics
import Foundation

enum ScreenshotMode: String, Codable, CaseIterable, Sendable {
    case area
    case window
    case fullScreen
}

enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case area
    case fullScreen
}

enum CaptureArtifactKind: String, Codable, Sendable {
    case screenshot
    case recording
}

struct CaptureArtifact: Equatable, Sendable {
    var id: UUID
    var kind: CaptureArtifactKind
    var fileURL: URL
    var createdAt: Date
    var duration: TimeInterval?
    var wasInterrupted: Bool

    init(
        id: UUID = UUID(),
        kind: CaptureArtifactKind,
        fileURL: URL,
        createdAt: Date = Date(),
        duration: TimeInterval? = nil,
        wasInterrupted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.duration = duration
        self.wasInterrupted = wasInterrupted
    }
}

enum CaptureDestination: Equatable, Sendable {
    case screenshots
    case recordings
}

struct ScreenshotRequest: Sendable {
    var mode: ScreenshotMode
    var selection: CGRect?
    var targetWindowID: CGWindowID?
    var excludesAtoll: Bool
    var destination: CaptureDestination

    init(
        mode: ScreenshotMode,
        selection: CGRect? = nil,
        targetWindowID: CGWindowID? = nil,
        excludesAtoll: Bool = true,
        destination: CaptureDestination = .screenshots
    ) {
        self.mode = mode
        self.selection = selection
        self.targetWindowID = targetWindowID
        self.excludesAtoll = excludesAtoll
        self.destination = destination
    }
}

enum CaptureError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case builtInDisplayUnavailable
    case selectionCancelled
    case invalidSelection
    case targetWindowUnavailable
    case emptyFrame
    case destinationAccessLost
    case encodingFailed
    case recordingAlreadyActive
    case recordingNotActive
    case streamFailed(String)
    case writerFailed(String)
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "Screen recording permission is required for screenshots and recordings.")
        case .builtInDisplayUnavailable: String(localized: "The built-in display is unavailable.")
        case .selectionCancelled: String(localized: "Capture cancelled.")
        case .invalidSelection: String(localized: "The selected area is too small.")
        case .targetWindowUnavailable: String(localized: "The selected window is no longer available.")
        case .emptyFrame: String(localized: "The captured frame is empty.")
        case .destinationAccessLost: String(localized: "Atoll can no longer access the selected save folder.")
        case .encodingFailed: String(localized: "The captured image could not be encoded.")
        case .recordingAlreadyActive: String(localized: "Atoll is already recording.")
        case .recordingNotActive: String(localized: "Atoll is not recording.")
        case let .streamFailed(message): String(localized: "Screen capture failed: \(message)")
        case let .writerFailed(message): String(localized: "The recording file could not be written: \(message)")
        case .microphoneDenied: String(localized: "Microphone access was denied. Recording can continue without the microphone.")
        }
    }
}
