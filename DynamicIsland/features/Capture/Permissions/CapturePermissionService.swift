/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import ApplicationServices
import Foundation
import ScreenCaptureKit

struct CapturePermissionService: Sendable {
    func verifyScreenCaptureAccess(requestIfNeeded: Bool) async throws {
        if !CGPreflightScreenCaptureAccess(), requestIfNeeded {
            guard CGRequestScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
    }
}
