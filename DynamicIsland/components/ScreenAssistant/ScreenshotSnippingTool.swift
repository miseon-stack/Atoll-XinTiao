/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Screen Assistant compatibility adapter. The capture implementation lives in
 * the phase-two ScreenCaptureKit service and no longer uses screencapture or
 * the system pasteboard as an intermediate buffer.
 */

import Combine
import Foundation

@MainActor
final class ScreenshotSnippingTool: ObservableObject {
    static let shared = ScreenshotSnippingTool()

    @Published private(set) var isSnipping = false
    @Published private(set) var lastError: CaptureError?

    enum ScreenshotType {
        case full
        case window
        case area

        var displayName: String {
            switch self {
            case .full: "Full Screen"
            case .window: "Window"
            case .area: "Area"
            }
        }

        var iconName: String {
            switch self {
            case .full: "rectangle.dashed"
            case .window: "macwindow"
            case .area: "viewfinder.rectangular"
            }
        }

        fileprivate var mode: ScreenshotMode {
            switch self {
            case .full: .fullScreen
            case .window: .window
            case .area: .area
            }
        }
    }

    private let service = ScreenCaptureService.shared
    private var task: Task<Void, Never>?

    func startSnipping(type: ScreenshotType = .area, completion: @escaping (URL) -> Void) {
        guard !isSnipping else { return }
        isSnipping = true
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSnipping = false
                self.task = nil
            }
            do {
                let artifact = try await service.capture(.init(mode: type.mode))
                completion(artifact.fileURL)
            } catch is CancellationError {
                lastError = .selectionCancelled
            } catch let error as CaptureError {
                lastError = error
            } catch {
                lastError = .streamFailed(error.localizedDescription)
            }
        }
    }

    func startAreaScreenshot(completion: @escaping (URL) -> Void) {
        startSnipping(type: .area, completion: completion)
    }

    func startFullScreenshot(completion: @escaping (URL) -> Void) {
        startSnipping(type: .full, completion: completion)
    }

    func startWindowScreenshot(completion: @escaping (URL) -> Void) {
        startSnipping(type: .window, completion: completion)
    }

    func cancelSnipping() {
        CaptureSelectionOverlay.shared.cancel()
        task?.cancel()
    }
}
