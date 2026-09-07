/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AppKit
import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import ScreenCaptureKit

@MainActor
protocol ScreenRecordingControlling: AnyObject {
    var state: RecordingState { get }
    func start(_ request: RecordingRequest) async
    func stop(reason: RecordingStopReason) async
    func cancelPreparation()
}

@MainActor
final class AtollRecordingCoordinator: ObservableObject, ScreenRecordingControlling {
    static let shared = AtollRecordingCoordinator()

    @Published private(set) var state: RecordingState = .idle {
        didSet {
            let enabled = Defaults[.enableShortcuts] && isRecording
            if enabled {
                KeyboardShortcuts.enable(.stopAtollRecording)
            } else {
                KeyboardShortcuts.disable(.stopAtollRecording)
            }
        }
    }
    @Published private(set) var microphoneWasDowngraded = false

    private let permissions = CapturePermissionService()
    private let fileStore = CaptureFileStore.shared
    private let finalizer = RecordingFileFinalizer()
    private var streamSession: ScreenStreamSession?
    private var sessionID: UUID?
    private var currentRequest: RecordingRequest?
    private var temporaryURL: URL?
    private var finalURL: URL?
    private var stopAccessingDestination: (@Sendable () -> Void)?
    private var durationTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var lifecycleCancellables = Set<AnyCancellable>()

    private init() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isBusy else { return }
                Task { @MainActor in await self.stop(reason: .streamInterrupted) }
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isBusy else { return }
                Task { @MainActor in await self.stop(reason: .streamInterrupted) }
            }
            .store(in: &lifecycleCancellables)
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .idle, .completed, .failed, .recoverable: false
        default: true
        }
    }

    func start(_ requested: RecordingRequest) async {
        guard !isBusy else { return }
        resetSessionState()
        microphoneWasDowngraded = false
        state = .preparing(.requestingPermission)

        do {
            try await permissions.verifyScreenCaptureAccess(requestIfNeeded: true)
            var request = requested
            if request.capturesMicrophone {
                request.capturesMicrophone = await microphoneAccessGranted()
                microphoneWasDowngraded = requested.capturesMicrophone && !request.capturesMicrophone
            }

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let target = try BuiltInDisplayResolver().resolve(from: content)
            var selection = request.selection
            if request.mode == .area, selection == nil {
                state = .preparing(.selectingArea)
                selection = await CaptureSelectionOverlay.shared.selectArea(on: target)
                guard selection != nil else { throw CaptureError.selectionCancelled }
            }

            state = .preparing(.preparingWriter)
            let urls = try await fileStore.recordingTemporaryAndFinalURLs()
            temporaryURL = urls.temporary
            finalURL = urls.final
            stopAccessingDestination = urls.stopAccessing

            let configuration = SCStreamConfiguration()
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true
            configuration.capturesAudio = request.capturesSystemAudio
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true

            let filter = SCContentFilter(
                display: target.scDisplay,
                excludingApplications: excludedApplications(content: content, enabled: request.excludesAtoll),
                exceptingWindows: []
            )
            let captureRect: CGRect
            if request.mode == .area {
                guard let selection else { throw CaptureError.invalidSelection }
                captureRect = CaptureCoordinateConverter.sourceRect(fromAppKit: selection, in: target)
                guard captureRect.width >= 16, captureRect.height >= 16 else { throw CaptureError.invalidSelection }
                configuration.sourceRect = captureRect
            } else {
                captureRect = CGRect(origin: .zero, size: target.screenFrame.size)
            }
            let width = even(Int(captureRect.width * target.scaleFactor))
            let height = even(Int(captureRect.height * target.scaleFactor))
            configuration.width = width
            configuration.height = height

            let writer = try RecordingAssetWriter(
                temporaryURL: urls.temporary,
                width: width,
                height: height,
                capturesSystemAudio: request.capturesSystemAudio,
                capturesMicrophone: request.capturesMicrophone
            )
            let microphone = request.capturesMicrophone ? MicrophoneCaptureSession() : nil
            let newSessionID = UUID()
            sessionID = newSessionID
            currentRequest = request
            streamSession = try ScreenStreamSession(
                sessionID: newSessionID,
                filter: filter,
                configuration: configuration,
                assetWriter: writer,
                microphone: microphone,
                onFirstFrame: { [weak self] id, uptime in
                    Task { @MainActor in self?.handleFirstFrame(sessionID: id, uptime: uptime) }
                },
                onInterruption: { [weak self] id, error in
                    Task { @MainActor in self?.handleInterruption(sessionID: id, error: error) }
                }
            )

            state = .preparing(.startingStream)
            try await streamSession?.start()
        } catch let error as CaptureError {
            failPreparation(error)
        } catch {
            failPreparation(.streamFailed(error.localizedDescription))
        }
    }

    func stop(reason: RecordingStopReason) async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard streamSession != nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStop(reason: reason)
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    func cancelPreparation() {
        guard case .preparing = state else { return }
        CaptureSelectionOverlay.shared.cancel()
        state = .idle
    }

    func resetCompletedState() {
        guard !isBusy else { return }
        state = .idle
    }

    private func performStop(reason: RecordingStopReason) async {
        guard let streamSession,
              let temporaryURL,
              let finalURL,
              let request = currentRequest else { return }
        durationTask?.cancel()
        durationTask = nil
        state = .stopping
        do {
            let writtenURL = try await streamSession.stop(
                ignoringStreamStopError: reason == .streamInterrupted
            )
            state = .finalizing(progress: nil)
            let artifact = try await finalizer.finalize(
                temporaryURL: writtenURL,
                finalURL: finalURL,
                mixesTwoAudioSources: request.capturesSystemAudio && request.capturesMicrophone,
                interrupted: reason == .streamInterrupted
            )
            stopAccessingDestination?()
            resetSessionReferences()
            state = .completed(artifact)
        } catch {
            stopAccessingDestination?()
            let failure = (error as? CaptureError) ?? .writerFailed(error.localizedDescription)
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                let manifest = RecoveryManifest(
                    sessionID: sessionID ?? UUID(),
                    createdAt: Date(),
                    temporaryFileURL: temporaryURL,
                    reason: failure.localizedDescription
                )
                resetSessionReferences(keepsTemporaryURL: true)
                state = .recoverable(manifest)
            } else {
                resetSessionReferences()
                state = .failed(failure)
            }
        }
    }

    private func handleFirstFrame(sessionID: UUID, uptime: TimeInterval) {
        guard self.sessionID == sessionID, let request = currentRequest else { return }
        state = .recording(.init(
            sessionID: sessionID,
            mode: request.mode,
            startedAtUptime: uptime,
            elapsed: 0,
            capturesSystemAudio: request.capturesSystemAudio,
            capturesMicrophone: request.capturesMicrophone
        ))
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.updateElapsed()
            }
        }
    }

    private func updateElapsed() {
        guard case var .recording(info) = state else { return }
        info.elapsed = max(0, ProcessInfo.processInfo.systemUptime - info.startedAtUptime)
        state = .recording(info)
    }

    private func handleInterruption(sessionID: UUID, error: Error) {
        guard self.sessionID == sessionID else { return }
        Task { await stop(reason: .streamInterrupted) }
    }

    private func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        @unknown default: false
        }
    }

    private func excludedApplications(content: SCShareableContent, enabled: Bool) -> [SCRunningApplication] {
        guard enabled, let bundleID = Bundle.main.bundleIdentifier else { return [] }
        return content.applications.filter { $0.bundleIdentifier == bundleID }
    }

    private func even(_ value: Int) -> Int { max(2, value - value % 2) }

    private func failPreparation(_ error: CaptureError) {
        stopAccessingDestination?()
        resetSessionReferences()
        state = error == .selectionCancelled ? .idle : .failed(error)
    }

    private func resetSessionState() {
        durationTask?.cancel()
        durationTask = nil
        resetSessionReferences()
    }

    private func resetSessionReferences(keepsTemporaryURL: Bool = false) {
        streamSession = nil
        sessionID = nil
        currentRequest = nil
        if !keepsTemporaryURL { temporaryURL = nil }
        finalURL = nil
        stopAccessingDestination = nil
    }
}
