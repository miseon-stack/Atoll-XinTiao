/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AVFoundation
import Foundation

struct RecordingFileFinalizer: Sendable {
    func finalize(
        temporaryURL: URL,
        finalURL: URL,
        mixesTwoAudioSources: Bool,
        interrupted: Bool
    ) async throws -> CaptureArtifact {
        let asset = AVURLAsset(url: temporaryURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw CaptureError.writerFailed("The file has no video track") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        if mixesTwoAudioSources, audioTracks.count >= 2 {
            try await exportMixed(asset: asset, videoTrack: videoTracks[0], audioTracks: Array(audioTracks.prefix(2)), to: finalURL)
            try? FileManager.default.removeItem(at: temporaryURL)
        } else {
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        }

        let completed = AVURLAsset(url: finalURL)
        let duration = try await completed.load(.duration)
        let tracks = try await completed.loadTracks(withMediaType: .video)
        let durationSeconds = CMTimeGetSeconds(duration)
        let fileSize = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !tracks.isEmpty,
              durationSeconds.isFinite,
              durationSeconds > 0,
              fileSize > 0 else {
            throw CaptureError.writerFailed("The completed file failed validation")
        }
        return CaptureArtifact(
            kind: .recording,
            fileURL: finalURL,
            duration: durationSeconds,
            wasInterrupted: interrupted
        )
    }

    private func exportMixed(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTracks: [AVAssetTrack],
        to outputURL: URL
    ) async throws {
        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.writerFailed("Video composition could not be created")
        }
        try compositionVideo.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in audioTracks {
            guard let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try compositionAudio.insertTimeRange(timeRange, of: track, at: .zero)
            let item = AVMutableAudioMixInputParameters(track: compositionAudio)
            item.setVolume(0.82, at: .zero)
            parameters.append(item)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CaptureError.writerFailed("Audio mix export is unavailable")
        }
        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.audioMix = mix
        exporter.shouldOptimizeForNetworkUse = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: CaptureError.writerFailed(exporter.error?.localizedDescription ?? "Audio mix failed"))
                }
            }
        }
    }
}
