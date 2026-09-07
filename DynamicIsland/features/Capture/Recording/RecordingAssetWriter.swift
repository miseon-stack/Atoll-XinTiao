/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AVFoundation
import CoreMedia

final class RecordingAssetWriter: @unchecked Sendable {
    enum AudioSource { case system, microphone }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.atoll.capture.asset-writer", qos: .userInitiated)
    private let temporaryURL: URL
    private(set) var startTime: CMTime?
    private var lastVideoPTS = CMTime.invalid
    private var lastSystemAudioPTS = CMTime.invalid
    private var lastMicrophonePTS = CMTime.invalid
    private var droppedFrames = 0
    private var finishing = false

    init(
        temporaryURL: URL,
        width: Int,
        height: Int,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool
    ) throws {
        self.temporaryURL = temporaryURL
        try? FileManager.default.removeItem(at: temporaryURL)
        writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)

        let pixelCount = max(1, width * height)
        let bitRate = min(24_000_000, max(5_000_000, pixelCount * 4))
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw CaptureError.writerFailed("Video input is unsupported") }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        if capturesSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureError.writerFailed("System audio input is unsupported") }
            writer.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }
        if capturesMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureError.writerFailed("Microphone input is unsupported") }
            writer.add(input)
            microphoneInput = input
        } else {
            microphoneInput = nil
        }
    }

    func appendVideo(_ buffer: CMSampleBuffer, onFirstFrame: @escaping @Sendable (TimeInterval) -> Void) {
        queue.async { [weak self] in
            guard let self, !finishing, CMSampleBufferDataIsReady(buffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if startTime == nil {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: pts)
                startTime = pts
                onFirstFrame(ProcessInfo.processInfo.systemUptime)
            }
            guard pts > lastVideoPTS else { return }
            guard videoInput.isReadyForMoreMediaData else {
                droppedFrames += 1
                return
            }
            if videoInput.append(buffer) { lastVideoPTS = pts }
        }
    }

    func appendAudio(_ buffer: CMSampleBuffer, source: AudioSource) {
        queue.async { [weak self] in
            guard let self, !finishing, let startTime, CMSampleBufferDataIsReady(buffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts >= startTime else { return }
            let input: AVAssetWriterInput?
            let lastPTS: CMTime
            switch source {
            case .system:
                input = systemAudioInput
                lastPTS = lastSystemAudioPTS
            case .microphone:
                input = microphoneInput
                lastPTS = lastMicrophonePTS
            }
            guard let input, pts > lastPTS, input.isReadyForMoreMediaData else { return }
            guard input.append(buffer) else { return }
            switch source {
            case .system: lastSystemAudioPTS = pts
            case .microphone: lastMicrophonePTS = pts
            }
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CaptureError.writerFailed("Writer was released"))
                    return
                }
                guard !finishing else {
                    continuation.resume(throwing: CaptureError.writerFailed("Writer is already finalizing"))
                    return
                }
                finishing = true
                guard startTime != nil else {
                    writer.cancelWriting()
                    continuation.resume(throwing: CaptureError.emptyFrame)
                    return
                }
                videoInput.markAsFinished()
                systemAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: self.temporaryURL)
                    } else {
                        continuation.resume(throwing: CaptureError.writerFailed(self.writer.error?.localizedDescription ?? "Unknown writer error"))
                    }
                }
            }
        }
    }
}
