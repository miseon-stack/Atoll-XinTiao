/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AppKit
import ScreenCaptureKit

struct BuiltInDisplayTarget {
    var cgDisplayID: CGDirectDisplayID
    var screenFrame: CGRect
    var quartzFrame: CGRect
    var scaleFactor: CGFloat
    var scDisplay: SCDisplay
    var screen: NSScreen
}

@MainActor
struct BuiltInDisplayResolver {
    static var hasSupportedBuiltInDisplay: Bool {
#if arch(arm64)
        NSScreen.screens.contains { screen in
            guard screen.safeAreaInsets.top > 0,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
#else
        false
#endif
    }

    func resolve(from content: SCShareableContent) throws -> BuiltInDisplayTarget {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard screen.safeAreaInsets.top > 0 else { return false }
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }),
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.builtInDisplayUnavailable
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.builtInDisplayUnavailable
        }
        return .init(
            cgDisplayID: displayID,
            screenFrame: screen.frame,
            quartzFrame: CGDisplayBounds(displayID),
            scaleFactor: screen.backingScaleFactor,
            scDisplay: display,
            screen: screen
        )
    }
}

enum CaptureCoordinateConverter {
    static func sourceRect(fromAppKit rect: CGRect, in target: BuiltInDisplayTarget) -> CGRect {
        let localX = rect.minX - target.screenFrame.minX
        let localY = rect.minY - target.screenFrame.minY
        return CGRect(
            x: max(0, localX),
            y: max(0, target.screenFrame.height - localY - rect.height),
            width: min(rect.width, target.screenFrame.width),
            height: min(rect.height, target.screenFrame.height)
        ).intersection(CGRect(origin: .zero, size: target.screenFrame.size))
    }

    static func appKitRect(fromQuartz rect: CGRect, in target: BuiltInDisplayTarget) -> CGRect {
        CGRect(
            x: target.screenFrame.minX + rect.minX - target.quartzFrame.minX,
            y: target.screenFrame.minY + target.screenFrame.height - (rect.maxY - target.quartzFrame.minY),
            width: rect.width,
            height: rect.height
        )
    }
}
