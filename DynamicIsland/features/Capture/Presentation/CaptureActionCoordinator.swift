/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AppKit
import Combine
import Defaults
import UserNotifications

@MainActor
final class CaptureActionCoordinator: ObservableObject {
    static let shared = CaptureActionCoordinator()

    @Published private(set) var isCapturingScreenshot = false
    @Published private(set) var lastArtifact: CaptureArtifact?
    @Published private(set) var lastError: CaptureError?
    @Published private(set) var isCaptureAvailable = BuiltInDisplayResolver.hasSupportedBuiltInDisplay

    private let screenshotService = ScreenCaptureService.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAvailability() }
            .store(in: &cancellables)
    }

    func refreshAvailability() {
        isCaptureAvailable = BuiltInDisplayResolver.hasSupportedBuiltInDisplay
        if !isCaptureAvailable { lastError = .builtInDisplayUnavailable }
    }

    func screenshot(_ mode: ScreenshotMode) async {
        refreshAvailability()
        guard isCaptureAvailable else { return }
        guard !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        lastError = nil
        defer { isCapturingScreenshot = false }
        do {
            let preferences = Defaults[.capturePreferences]
            let artifact = try await screenshotService.capture(.init(
                mode: mode,
                excludesAtoll: preferences.excludesAtollFromCapture
            ))
            lastArtifact = artifact
            await CaptureCompletionFeedback.present(artifact)
        } catch let error as CaptureError {
            if error != .selectionCancelled { lastError = error }
        } catch {
            lastError = .streamFailed(error.localizedDescription)
        }
    }

    func startRecording(_ mode: RecordingMode) async {
        refreshAvailability()
        guard isCaptureAvailable else { return }
        let preferences = Defaults[.capturePreferences]
        await AtollRecordingCoordinator.shared.start(.init(
            mode: mode,
            capturesSystemAudio: preferences.capturesSystemAudio,
            capturesMicrophone: preferences.capturesMicrophone,
            excludesAtoll: preferences.excludesAtollFromCapture
        ))
    }

    func stopRecording(reason: RecordingStopReason = .user) async {
        await AtollRecordingCoordinator.shared.stop(reason: reason)
        if case let .completed(artifact) = AtollRecordingCoordinator.shared.state {
            lastArtifact = artifact
            await CaptureCompletionFeedback.present(artifact)
        }
    }

    func copy(_ artifact: CaptureArtifact) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if artifact.kind == .screenshot, let image = NSImage(contentsOf: artifact.fileURL) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.writeObjects([artifact.fileURL as NSURL])
        }
    }

    func open(_ artifact: CaptureArtifact) {
        NSWorkspace.shared.open(artifact.fileURL)
    }

    func reveal(_ artifact: CaptureArtifact) {
        NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL])
    }
}

enum CaptureCompletionFeedback {
    static func present(_ artifact: CaptureArtifact) async {
        guard Defaults[.capturePreferences].completionNotificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        CaptureNotificationDelegate.shared.configure(center)
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = artifact.kind == .screenshot
            ? String(localized: "Screenshot saved")
            : String(localized: "Recording saved")
        content.body = artifact.fileURL.lastPathComponent
        content.sound = .default
        content.categoryIdentifier = CaptureNotificationDelegate.categoryIdentifier
        content.userInfo = ["capturePath": artifact.fileURL.path]
        try? await center.add(UNNotificationRequest(identifier: artifact.id.uuidString, content: content, trigger: nil))
    }
}

final class CaptureNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CaptureNotificationDelegate()
    static let categoryIdentifier = "ATOLL_CAPTURE_COMPLETED"
    private static let openAction = "ATOLL_CAPTURE_OPEN"
    private static let revealAction = "ATOLL_CAPTURE_REVEAL"

    func configure(_ center: UNUserNotificationCenter) {
        center.delegate = self
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: Self.openAction, title: String(localized: "Open")),
                UNNotificationAction(identifier: Self.revealAction, title: String(localized: "Show in Finder"))
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let path = response.notification.request.content.userInfo["capturePath"] as? String else { return }
        let url = URL(fileURLWithPath: path)
        DispatchQueue.main.async {
            if response.actionIdentifier == Self.revealAction {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
