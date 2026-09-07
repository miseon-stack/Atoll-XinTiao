/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class ScreenStreamSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream!
    private let assetWriter: RecordingAssetWriter
    private let microphone: MicrophoneCaptureSession?
    private let screenQueue = DispatchQueue(label: "com.atoll.capture.screen", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.atoll.capture.system-audio", qos: .userInitiated)
    private let sessionID: UUID
    private let onFirstFrame: @Sendable (UUID, TimeInterval) -> Void
    private let onInterruption: @Sendable (UUID, Error) -> Void

    init(
        sessionID: UUID,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        assetWriter: RecordingAssetWriter,
        microphone: MicrophoneCaptureSession?,
        onFirstFrame: @escaping @Sendable (UUID, TimeInterval) -> Void,
        onInterruption: @escaping @Sendable (UUID, Error) -> Void
    ) throws {
        self.sessionID = sessionID
        self.assetWriter = assetWriter
        self.microphone = microphone
        self.onFirstFrame = onFirstFrame
        self.onInterruption = onInterruption
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        microphone?.onSampleBuffer = { [weak assetWriter] buffer in
            assetWriter?.appendAudio(buffer, source: .microphone)
        }
    }

    func start() async throws {
        try microphone?.start()
        do {
            try await stream.startCapture()
        } catch {
            microphone?.stop()
            throw error
        }
    }

    func stop(ignoringStreamStopError: Bool = false) async throws -> URL {
        microphone?.stop()
        do {
            try await stream.stopCapture()
        } catch where ignoringStreamStopError {
            // ScreenCaptureKit has already stopped an interrupted stream. The
            // writer can still contain a valid, playable recording.
        }
        return try await assetWriter.finish()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            assetWriter.appendVideo(sampleBuffer) { [sessionID, onFirstFrame] uptime in
                onFirstFrame(sessionID, uptime)
            }
        case .audio:
            assetWriter.appendAudio(sampleBuffer, source: .system)
        case .microphone:
            assetWriter.appendAudio(sampleBuffer, source: .microphone)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterruption(sessionID, error)
    }
}
