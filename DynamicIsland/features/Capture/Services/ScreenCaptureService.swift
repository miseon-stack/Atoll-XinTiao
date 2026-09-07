/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
protocol ScreenCaptureServicing: AnyObject {
    func capture(_ request: ScreenshotRequest) async throws -> CaptureArtifact
}

@MainActor
final class ScreenCaptureService: ScreenCaptureServicing {
    static let shared = ScreenCaptureService()

    private let permissionService = CapturePermissionService()
    private let fileStore = CaptureFileStore.shared
    private let selector = CaptureSelectionOverlay.shared

    func capture(_ request: ScreenshotRequest) async throws -> CaptureArtifact {
        try await permissionService.verifyScreenCaptureAccess(requestIfNeeded: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = try BuiltInDisplayResolver().resolve(from: content)

        var selection = request.selection
        var windowID = request.targetWindowID
        if request.mode == .area, selection == nil {
            selection = await selector.selectArea(on: target)
            guard selection != nil else { throw CaptureError.selectionCancelled }
        } else if request.mode == .window, windowID == nil {
            windowID = await selector.selectWindow(on: target, windows: eligibleWindows(content.windows, target: target))
            guard windowID != nil else { throw CaptureError.selectionCancelled }
        }

        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        switch request.mode {
        case .fullScreen:
            filter = SCContentFilter(
                display: target.scDisplay,
                excludingApplications: excludedApplications(in: content, enabled: request.excludesAtoll),
                exceptingWindows: []
            )
            configuration.width = Int(target.screenFrame.width * target.scaleFactor)
            configuration.height = Int(target.screenFrame.height * target.scaleFactor)
        case .area:
            guard let selection else { throw CaptureError.invalidSelection }
            let sourceRect = CaptureCoordinateConverter.sourceRect(fromAppKit: selection, in: target)
            guard sourceRect.width >= 16, sourceRect.height >= 16 else { throw CaptureError.invalidSelection }
            filter = SCContentFilter(
                display: target.scDisplay,
                excludingApplications: excludedApplications(in: content, enabled: request.excludesAtoll),
                exceptingWindows: []
            )
            configuration.sourceRect = sourceRect
            configuration.width = Int(sourceRect.width * target.scaleFactor)
            configuration.height = Int(sourceRect.height * target.scaleFactor)
        case .window:
            guard let windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.targetWindowUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.width = max(2, Int(window.frame.width * target.scaleFactor))
            configuration.height = max(2, Int(window.frame.height * target.scaleFactor))
        }

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw CaptureError.streamFailed(error.localizedDescription)
        }
        return try await fileStore.savePNG(image, destination: request.destination)
    }

    private func eligibleWindows(_ windows: [SCWindow], target: BuiltInDisplayTarget) -> [SCWindow] {
        let displayBounds = target.quartzFrame
        return windows.filter {
            $0.isOnScreen
                && $0.frame.width >= 40
                && $0.frame.height >= 40
                && $0.frame.intersects(displayBounds)
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    private func excludedApplications(in content: SCShareableContent, enabled: Bool) -> [SCRunningApplication] {
        guard enabled, let bundleID = Bundle.main.bundleIdentifier else { return [] }
        return content.applications.filter { $0.bundleIdentifier == bundleID }
    }
}
