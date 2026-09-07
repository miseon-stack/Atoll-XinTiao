/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AVFoundation
import CoreMedia

final class MicrophoneCaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.atoll.capture.microphone", qos: .userInitiated)
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.microphoneDenied
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureError.streamFailed("Microphone input is unavailable")
        }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}
