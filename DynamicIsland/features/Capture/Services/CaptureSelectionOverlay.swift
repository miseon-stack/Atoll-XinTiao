/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AppKit
import QuartzCore
import ScreenCaptureKit

@MainActor
final class CaptureSelectionOverlay {
    static let shared = CaptureSelectionOverlay()

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<CaptureSelectionResult?, Never>?

    func selectArea(on target: BuiltInDisplayTarget) async -> CGRect? {
        await present(mode: .area, target: target, windows: [])?.rect
    }

    func selectWindow(on target: BuiltInDisplayTarget, windows: [SCWindow]) async -> CGWindowID? {
        await present(mode: .window, target: target, windows: windows)?.windowID
    }

    func cancel() {
        finish(nil)
    }

    private func present(
        mode: CaptureSelectionMode,
        target: BuiltInDisplayTarget,
        windows: [SCWindow]
    ) async -> CaptureSelectionResult? {
        guard panel == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let panel = CaptureOverlayPanel(
                contentRect: target.screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: target.screen
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false

            let view = CaptureSelectionView(mode: mode, target: target, windows: windows) { [weak self] result in
                self?.finish(result)
            }
            panel.contentView = view
            self.panel = panel
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        }
    }

    private func finish(_ result: CaptureSelectionResult?) {
        guard let continuation else { return }
        self.continuation = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        // Resume only after the overlay has been ordered out and the WindowServer
        // transaction has been flushed, so no arbitrary sleep is needed.
        CATransaction.flush()
        DispatchQueue.main.async { continuation.resume(returning: result) }
    }
}

private final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum CaptureSelectionMode {
    case area
    case window
}

private struct CaptureSelectionResult {
    var rect: CGRect?
    var windowID: CGWindowID?
}

private final class CaptureSelectionView: NSView {
    private let mode: CaptureSelectionMode
    private let target: BuiltInDisplayTarget
    private let windows: [SCWindow]
    private let completion: (CaptureSelectionResult?) -> Void
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindowID: CGWindowID?

    override var acceptsFirstResponder: Bool { true }

    init(
        mode: CaptureSelectionMode,
        target: BuiltInDisplayTarget,
        windows: [SCWindow],
        completion: @escaping (CaptureSelectionResult?) -> Void
    ) {
        self.mode = mode
        self.target = target
        self.windows = windows
        self.completion = completion
        super.init(frame: CGRect(origin: .zero, size: target.screenFrame.size))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        dirtyRect.fill()

        if mode == .area, let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            path.stroke()
            drawLabel("\(Int(selection.width)) × \(Int(selection.height))", near: selection)
        } else if mode == .window, let hoveredWindowID,
                  let window = windows.first(where: { $0.windowID == hoveredWindowID }) {
            let global = CaptureCoordinateConverter.appKitRect(fromQuartz: window.frame, in: target)
            let local = convert(global, from: nil)
            NSColor.systemBlue.withAlphaComponent(0.22).setFill()
            local.fill()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: local)
            path.lineWidth = 3
            path.stroke()
            drawLabel(window.title ?? String(localized: "Window"), near: local)
        }

        let instruction = mode == .area
            ? String(localized: "Drag to select an area · Esc to cancel")
            : String(localized: "Click a window · Esc to cancel")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ]
        let size = instruction.size(withAttributes: attributes)
        instruction.draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 30),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mode == .area {
            dragStart = point
            selection = CGRect(origin: point, size: .zero)
        } else if let id = windowID(at: point) {
            completion(.init(rect: nil, windowID: id))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = dragStart else { return }
        selection = normalizedRect(from: start, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let selection else { return }
        guard selection.width >= 16, selection.height >= 16 else {
            completion(nil)
            return
        }
        let global = convert(selection, to: nil)
        completion(.init(rect: global, windowID: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        hoveredWindowID = windowID(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            completion(nil)
        } else if event.keyCode == 36, mode == .area, let selection,
                  selection.width >= 16, selection.height >= 16 {
            completion(.init(rect: convert(selection, to: nil), windowID: nil))
        } else {
            super.keyDown(with: event)
        }
    }

    private func windowID(at localPoint: CGPoint) -> CGWindowID? {
        let globalAppKit = convert(localPoint, to: nil)
        let quartzPoint = CGPoint(
            x: target.quartzFrame.minX + globalAppKit.x - target.screenFrame.minX,
            y: target.quartzFrame.minY + target.screenFrame.height - (globalAppKit.y - target.screenFrame.minY)
        )
        return windows
            .filter { $0.isOnScreen && $0.frame.contains(quartzPoint) && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            .min { lhs, rhs in lhs.windowLayer < rhs.windowLayer }?
            .windowID
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func drawLabel(_ value: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.85)
        ]
        value.draw(at: CGPoint(x: rect.minX + 6, y: max(6, rect.minY - 22)), withAttributes: attributes)
    }
}
