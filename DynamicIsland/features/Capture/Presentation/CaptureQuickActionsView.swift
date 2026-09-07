/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import SwiftUI

struct CaptureQuickActionsView: View {
    @ObservedObject private var actions = CaptureActionCoordinator.shared
    @ObservedObject private var recording = AtollRecordingCoordinator.shared
    var showsShortcutSettingsButton = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(String(localized: "Capture"), systemImage: "viewfinder")
                    .font(.headline)
                Spacer()
                recordingStatus
                if showsShortcutSettingsButton {
                    Button {
                        SettingsWindowController.shared.showCaptureShortcutSettings()
                    } label: {
                        Label(String(localized: "Keyboard shortcuts"), systemImage: "keyboard")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Configure screenshot and recording shortcuts"))
                }
            }
            HStack(spacing: 8) {
                captureButton(String(localized: "Area"), icon: "viewfinder.rectangular") {
                    await actions.screenshot(.area)
                }
                captureButton(String(localized: "Window"), icon: "macwindow") {
                    await actions.screenshot(.window)
                }
                captureButton(String(localized: "Screen"), icon: "display") {
                    await actions.screenshot(.fullScreen)
                }

                Divider().frame(height: 24)

                if recording.isBusy {
                    captureButton(
                        String(localized: "Stop"),
                        icon: "stop.circle.fill",
                        tint: .red,
                        allowsWhenBusy: true
                    ) {
                        await actions.stopRecording()
                    }
                } else {
                    captureButton(String(localized: "Record Area"), icon: "record.circle") {
                        await actions.startRecording(.area)
                    }
                    captureButton(String(localized: "Record Screen"), icon: "rectangle.inset.filled.and.person.filled") {
                        await actions.startRecording(.fullScreen)
                    }
                }
            }
            .buttonStyle(.borderless)

            if let artifact = latestArtifact {
                HStack(spacing: 12) {
                    if artifact.kind == .screenshot,
                       let image = NSImage(contentsOf: artifact.fileURL) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(artifact.fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(String(localized: "Copy")) { actions.copy(artifact) }
                    Button(String(localized: "Open")) { actions.open(artifact) }
                    Button(String(localized: "Show in Finder")) { actions.reveal(artifact) }
                }
                .font(.caption)
            } else if let error = currentError {
                HStack {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    if error == .permissionDenied {
                        Button(String(localized: "Open System Settings")) {
                            openScreenCaptureSettings()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var recordingStatus: some View {
        switch recording.state {
        case let .recording(info):
            Label(duration(info.elapsed), systemImage: "record.circle.fill")
                .foregroundStyle(.red)
                .font(.caption.monospacedDigit())
        case .preparing: Text(String(localized: "Preparing…")).font(.caption).foregroundStyle(.secondary)
        case .stopping, .finalizing: Text(String(localized: "Finalizing…")).font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    private var latestArtifact: CaptureArtifact? {
        if case let .completed(value) = recording.state { return value }
        return actions.lastArtifact
    }

    private var currentError: CaptureError? {
        if case let .failed(error) = recording.state { return error }
        return actions.lastError
    }

    private func captureButton(
        _ title: String,
        icon: String,
        tint: Color = .primary,
        allowsWhenBusy: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(tint)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .disabled(actions.isCapturingScreenshot || (recording.isBusy && !allowsWhenBusy))
        .disabled(!actions.isCaptureAvailable)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
