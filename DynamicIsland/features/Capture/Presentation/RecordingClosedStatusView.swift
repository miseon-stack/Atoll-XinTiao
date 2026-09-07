/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import SwiftUI

struct RecordingClosedStatusView: View {
    let elapsed: TimeInterval

    var body: some View {
        Button {
            Task { await CaptureActionCoordinator.shared.stopRecording() }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(.red).frame(width: 7, height: 7)
                if elapsed < 6_000 {
                    Text(formatted)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .fontWidth(.compressed)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Stop recording"))
        .accessibilityLabel(String(localized: "Screen recording in progress"))
        .accessibilityValue(formatted)
    }

    private var formatted: String {
        let total = max(0, Int(elapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
