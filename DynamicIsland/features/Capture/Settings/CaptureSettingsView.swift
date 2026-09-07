/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AppKit
import Defaults
import KeyboardShortcuts
import SwiftUI

struct CaptureSettingsView: View {
    @Default(.capturePreferences) private var preferences
    @ObservedObject private var actions = CaptureActionCoordinator.shared
    @ObservedObject private var recording = AtollRecordingCoordinator.shared
    @State private var folderError: String?
    @State private var shortcutRevision = 0
    @State private var duplicateShortcutRejected = false

    var body: some View {
        Form {
            Section(String(localized: "Audio")) {
                Toggle(String(localized: "Record system audio"), isOn: $preferences.capturesSystemAudio)
                Toggle(String(localized: "Record microphone"), isOn: $preferences.capturesMicrophone)
                if recording.microphoneWasDowngraded {
                    Label(String(localized: "Microphone access was unavailable. The current recording continues without it."), systemImage: "mic.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section(String(localized: "Save locations")) {
                folderRow(title: String(localized: "Screenshots"), destination: .screenshots)
                folderRow(title: String(localized: "Recordings"), destination: .recordings)
            }

            Section(String(localized: "Behavior")) {
                Toggle(String(localized: "Exclude Atoll from captures"), isOn: $preferences.excludesAtollFromCapture)
                Toggle(String(localized: "Show completion notifications"), isOn: $preferences.completionNotificationsEnabled)
            }

            Section(String(localized: "Quick actions")) {
                CaptureQuickActionsView(showsShortcutSettingsButton: false)
            }

            Section(String(localized: "Keyboard shortcuts")) {
                KeyboardShortcuts.Recorder(String(localized: "Area screenshot"), name: .captureAreaScreenshot)
                KeyboardShortcuts.Recorder(String(localized: "Window screenshot"), name: .captureWindowScreenshot)
                KeyboardShortcuts.Recorder(String(localized: "Full-screen screenshot"), name: .captureFullScreenshot)
                KeyboardShortcuts.Recorder(String(localized: "Start area recording"), name: .startAreaRecording)
                KeyboardShortcuts.Recorder(String(localized: "Start full-screen recording"), name: .startFullRecording)
                KeyboardShortcuts.Recorder(String(localized: "Toggle recording"), name: .toggleAtollRecording)
                KeyboardShortcuts.Recorder(String(localized: "Stop recording"), name: .stopAtollRecording)
                if duplicateShortcutRejected || !shortcutConflicts.isEmpty {
                    Label(
                        String(localized: "Duplicate capture shortcuts are disabled after the first matching action."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .settingsHighlight(id: SettingsNavigationTarget.captureShortcutsHighlightID)

            if let folderError {
                Section { Label(folderError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .navigationTitle(String(localized: "Screenshot & Recording"))
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"))) { notification in
            shortcutRevision += 1
            rejectDuplicateShortcut(from: notification)
        }
    }

    private func folderRow(title: String, destination: CaptureDestination) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(folderPath(destination)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(String(localized: "Choose…")) { chooseFolder(destination) }
            Button(String(localized: "Default")) { resetFolder(destination) }
        }
    }

    private func folderPath(_ destination: CaptureDestination) -> String {
        (try? CaptureFileStorePathResolver.displayFolder(destination).path(percentEncoded: false))
            ?? String(localized: "Folder unavailable")
    }

    private func chooseFolder(_ destination: CaptureDestination) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try CaptureFileStore.bookmark(for: url)
            if destination == .screenshots {
                preferences.screenshotFolderBookmark = bookmark
            } else {
                preferences.recordingFolderBookmark = bookmark
            }
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
    }

    private func resetFolder(_ destination: CaptureDestination) {
        if destination == .screenshots {
            preferences.screenshotFolderBookmark = nil
        } else {
            preferences.recordingFolderBookmark = nil
        }
        folderError = nil
    }

    private var shortcutConflicts: [KeyboardShortcuts.Shortcut] {
        _ = shortcutRevision
        let names: [KeyboardShortcuts.Name] = [
            .captureAreaScreenshot, .captureWindowScreenshot, .captureFullScreenshot,
            .startAreaRecording, .startFullRecording, .toggleAtollRecording, .stopAtollRecording
        ]
        let values = names.compactMap { KeyboardShortcuts.getShortcut(for: $0) }
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
        return counts.filter { $0.value > 1 }.map(\.key)
    }

    private var captureShortcutNames: [KeyboardShortcuts.Name] {
        [
            .captureAreaScreenshot, .captureWindowScreenshot, .captureFullScreenshot,
            .startAreaRecording, .startFullRecording, .toggleAtollRecording, .stopAtollRecording
        ]
    }

    private func rejectDuplicateShortcut(from notification: Notification) {
        guard let changedName = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
              captureShortcutNames.contains(changedName),
              let changedShortcut = KeyboardShortcuts.getShortcut(for: changedName) else { return }
        let duplicate = captureShortcutNames.contains { name in
            name != changedName && KeyboardShortcuts.getShortcut(for: name) == changedShortcut
        }
        guard duplicate else {
            duplicateShortcutRejected = false
            return
        }
        duplicateShortcutRejected = true
        KeyboardShortcuts.setShortcut(nil, for: changedName)
    }
}

private enum CaptureFileStorePathResolver {
    static func displayFolder(_ destination: CaptureDestination) throws -> URL {
        let preferences = Defaults[.capturePreferences]
        let bookmark = destination == .screenshots ? preferences.screenshotFolderBookmark : preferences.recordingFolderBookmark
        if let bookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            guard !stale else { throw CaptureError.destinationAccessLost }
            return url
        }
        let directory: FileManager.SearchPathDirectory = destination == .screenshots ? .picturesDirectory : .moviesDirectory
        guard let base = FileManager.default.urls(for: directory, in: .userDomainMask).first else { throw CaptureError.destinationAccessLost }
        return base.appendingPathComponent(destination == .screenshots ? "Atoll Screenshots" : "Atoll Recordings")
    }
}
