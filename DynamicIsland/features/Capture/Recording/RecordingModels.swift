/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import CoreGraphics
import Foundation

enum RecordingPreparationStage: String, Equatable, Sendable {
    case requestingPermission
    case selectingArea
    case preparingWriter
    case startingStream
}

struct ActiveRecordingInfo: Equatable, Sendable {
    var sessionID: UUID
    var mode: RecordingMode
    var startedAtUptime: TimeInterval
    var elapsed: TimeInterval
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
}

struct RecoveryManifest: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var sessionID: UUID
    var createdAt: Date
    var temporaryFileURL: URL
    var reason: String
}

enum RecordingState: Equatable, Sendable {
    case idle
    case preparing(RecordingPreparationStage)
    case recording(ActiveRecordingInfo)
    case stopping
    case finalizing(progress: Double?)
    case completed(CaptureArtifact)
    case recoverable(RecoveryManifest)
    case failed(CaptureError)
}

enum RecordingStopReason: String, Sendable {
    case user
    case shortcut
    case applicationTermination
    case streamInterrupted
}

struct RecordingRequest: Sendable {
    var mode: RecordingMode
    var selection: CGRect?
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var excludesAtoll: Bool

    init(
        mode: RecordingMode,
        selection: CGRect? = nil,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        excludesAtoll: Bool = true
    ) {
        self.mode = mode
        self.selection = selection
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.excludesAtoll = excludesAtoll
    }
}
