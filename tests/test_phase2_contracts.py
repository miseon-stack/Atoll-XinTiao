#!/usr/bin/env python3
"""Static contract checks for Phase 2 platform and privacy boundaries."""

from pathlib import Path
import json
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]


class Phase2ContractTests(unittest.TestCase):
    def test_official_calendar_document(self):
        path = ROOT / "DynamicIsland" / "HolidayCalendars" / "cn-2026.json"
        document = json.loads(path.read_text())
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["calendar"], "CN")
        self.assertEqual(document["year"], 2026)
        self.assertIn("国办发明电〔2025〕7号", document["sourceTitle"])
        dates = document["dates"]
        self.assertEqual(len({item["date"] for item in dates}), len(dates))
        self.assertEqual(
            {item["date"] for item in dates if item["kind"] == "makeupWorkday"},
            {"2026-01-04", "2026-02-14", "2026-02-28", "2026-05-09", "2026-09-20", "2026-10-10"},
        )

    def test_screenshot_does_not_use_process_or_pasteboard_transport(self):
        paths = [
            ROOT / "DynamicIsland" / "components" / "ScreenAssistant" / "ScreenshotSnippingTool.swift",
            ROOT / "DynamicIsland" / "features" / "Capture" / "Services" / "ScreenCaptureService.swift",
        ]
        text = "\n".join(path.read_text() for path in paths)
        self.assertNotIn("/usr/sbin/screencapture", text)
        self.assertNotIn("Process()", text)
        self.assertNotIn("NSPasteboard", text)
        self.assertIn("SCScreenshotManager.captureImage", text)

    def test_recording_uses_macos_14_compatible_primary_path(self):
        root = ROOT / "DynamicIsland" / "features" / "Capture" / "Recording"
        text = "\n".join(path.read_text() for path in root.glob("*.swift"))
        self.assertIn("SCStream", text)
        self.assertIn("AVAssetWriter", text)
        self.assertNotIn("SCRecordingOutput", text)
        self.assertIn("AVCaptureAudioDataOutput", text)

    def test_permissions_and_entitlements(self):
        with (ROOT / "DynamicIsland" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        with (ROOT / "DynamicIsland" / "DynamicIsland.entitlements").open("rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertIn("screenshots or screen recordings", info["NSScreenCaptureUsageDescription"])
        self.assertIn("NSMicrophoneUsageDescription", info)
        self.assertTrue(entitlements["com.apple.security.device.audio-input"])

    def test_capture_shortcuts_have_no_defaults(self):
        text = (ROOT / "DynamicIsland" / "Shortcuts" / "ShortcutConstants.swift").read_text()
        for name in (
            "captureAreaScreenshot", "captureWindowScreenshot", "captureFullScreenshot",
            "startAreaRecording", "startFullRecording", "toggleAtollRecording", "stopAtollRecording",
        ):
            line = next(line for line in text.splitlines() if f'"{name}"' in line)
            self.assertNotIn("default:", line)

    def test_no_multi_display_capture_selection(self):
        root = ROOT / "DynamicIsland" / "features" / "Capture"
        text = "\n".join(path.read_text() for path in root.rglob("*.swift"))
        self.assertIn("CGDisplayIsBuiltin", text)
        self.assertIn("safeAreaInsets.top > 0", text)
        self.assertNotIn("selectedDisplay", text)
        self.assertNotIn("externalDisplay", text)

    def test_capture_shortcut_conflicts_have_one_guarded_editor(self):
        source = ROOT / "DynamicIsland"
        text = "\n".join(path.read_text() for path in source.rglob("*.swift"))
        self.assertEqual(text.count("name: .captureAreaScreenshot)"), 1)
        self.assertIn("rejectDuplicateShortcut", text)
        self.assertIn("KeyboardShortcuts.setShortcut(nil, for: changedName)", text)
        quick_actions = (
            source / "features" / "Capture" / "Presentation" /
            "CaptureQuickActionsView.swift"
        ).read_text()
        self.assertIn("showCaptureShortcutSettings()", quick_actions)
        self.assertIn('String(localized: "Keyboard shortcuts")', quick_actions)
        settings_controller = (
            source / "components" / "Settings" / "SettingsWindowController.swift"
        ).read_text()
        self.assertIn("atollOpenCaptureShortcutSettings", settings_controller)
        settings = (source / "components" / "Settings" / "SettingsView.swift").read_text()
        self.assertIn("selectedTab = .capture", settings)
        capture_settings = (
            source / "features" / "Capture" / "Settings" /
            "CaptureSettingsView.swift"
        ).read_text()
        self.assertIn("SettingsNavigationTarget.captureShortcutsHighlightID", capture_settings)

    def test_recording_lifecycle_interruptions_are_handled(self):
        coordinator = (
            ROOT / "DynamicIsland" / "features" / "Capture" / "Recording" /
            "AtollRecordingCoordinator.swift"
        ).read_text()
        session = (
            ROOT / "DynamicIsland" / "features" / "Capture" / "Recording" /
            "ScreenStreamSession.swift"
        ).read_text()
        self.assertIn("NSWorkspace.willSleepNotification", coordinator)
        self.assertIn("NSApplication.didChangeScreenParametersNotification", coordinator)
        self.assertIn("ignoringStreamStopError: reason == .streamInterrupted", coordinator)
        self.assertIn("ignoringStreamStopError", session)

    def test_live_earnings_modal_keeps_notch_open(self):
        source = (
            ROOT / "DynamicIsland" / "features" / "LiveEarnings" /
            "LiveEarningsViews.swift"
        ).read_text()
        self.assertIn(".sheet(item: $presentedSheet", source)
        self.assertIn(
            "setAutoCloseSuppression(true, token: autoCloseSuppressionToken)",
            source,
        )
        self.assertIn(
            "setAutoCloseSuppression(false, token: autoCloseSuppressionToken)",
            source,
        )
        self.assertNotIn(".sheet(isPresented: $showsWorkCalendar)", source)

    def test_work_calendar_is_a_standalone_notch_tab(self):
        tabs = (ROOT / "DynamicIsland" / "components" / "Tabs" / "TabSelectionView.swift").read_text()
        home = (ROOT / "DynamicIsland" / "components" / "Notch" / "NotchHomeView.swift").read_text()
        calendar = (
            ROOT / "DynamicIsland" / "features" / "LiveEarnings" / "Calendar" /
            "WorkCalendarViews.swift"
        ).read_text()
        service = (ROOT / "DynamicIsland" / "Providers" / "CalendarServiceProviding.swift").read_text()

        self.assertIn('icon: "calendar", view: .calendar', tabs)
        self.assertNotIn("StandaloneCalendarView()", home)
        self.assertNotIn("CalendarView()", home)
        self.assertIn("struct NotchWorkCalendarView", calendar)
        notch_calendar = calendar.split("struct NotchWorkCalendarView", 1)[1]
        self.assertIn("private var calendarRows: [[Date?]]", notch_calendar)
        self.assertIn("ForEach(Array(calendarRows.enumerated())", notch_calendar)
        self.assertIn("max(0, 42 - slots.count)", notch_calendar)
        self.assertIn("ScrollView(.vertical, showsIndicators: true) {\n                dayPane", notch_calendar)
        self.assertIn('String(localized: "Add To-Do")', notch_calendar)
        self.assertIn('String(localized: "Add Event")', notch_calendar)
        self.assertIn("private var creationOverlay", notch_calendar)
        self.assertNotIn('String(localized: "Tomorrow")', notch_calendar)
        self.assertIn("monthItemsByDay", notch_calendar)
        self.assertNotIn("@State private var monthItemsByDay", notch_calendar)
        self.assertIn("calendarManager.cachedWorkCalendarItems(for: displayedMonth)", notch_calendar)
        self.assertIn("eventCount: items.filter", notch_calendar)
        self.assertIn("todoCount: items.filter", notch_calendar)
        self.assertIn("private var calendarItemIndicators", calendar)
        self.assertNotIn(".overlay(alignment: .bottomTrailing)", calendar)
        self.assertIn("await refreshMonthItems(for: displayedMonth)", notch_calendar)
        self.assertIn("await calendarManager.prepareWorkCalendarAccess()", notch_calendar)
        self.assertIn("Task.sleep(nanoseconds: 320_000_000)", notch_calendar)
        manager = (ROOT / "DynamicIsland" / "managers" / "CalendarManager.swift").read_text()
        self.assertIn("func calendarItems(from startDate: Date, to endDate: Date)", manager)
        self.assertIn("workCalendarItemsByMonth", manager)
        self.assertIn("preloadCurrentWorkCalendarMonthIfAuthorized()", manager)
        self.assertIn("func cachedWorkCalendarItems(for month: Date)", manager)
        self.assertIn("calendars: []", manager)
        self.assertIn("func prepareWorkCalendarAccess() async", manager)
        coordinator = (ROOT / "DynamicIsland" / "DynamicIslandViewCoordinator.swift").read_text()
        self.assertIn("var tabSwitchForward: Bool = true", coordinator)
        self.assertNotIn("@Published var tabSwitchForward", coordinator)
        self.assertIn("selectedDayItems", notch_calendar)
        self.assertIn("beginEditing(event)", notch_calendar)
        self.assertIn("toggleReminderCompletion(event)", notch_calendar)
        self.assertIn("itemPendingDeletion = event", notch_calendar)
        self.assertIn("showsDayItemsOverlay", notch_calendar)
        self.assertNotIn('String(localized: "View %lld Items")', notch_calendar)
        self.assertIn("doubleAction:", calendar)
        self.assertIn("TapGesture(count: 2)", calendar)
        double_action = notch_calendar.split("} doubleAction: {", 1)[1]
        double_action = double_action.split("}", 1)[0]
        self.assertIn("showsDayItemsOverlay = true", double_action)
        self.assertNotIn("items.isEmpty", double_action)
        day_items_overlay = notch_calendar.split("private var dayItemsOverlay", 1)[1]
        day_items_overlay = day_items_overlay.split("private func deletionOverlay", 1)[0]
        self.assertIn('String(localized: "Add Event")', day_items_overlay)
        self.assertIn('String(localized: "Add To-Do")', day_items_overlay)
        self.assertIn('String(localized: "No events or to-dos for this day.")', day_items_overlay)
        self.assertIn("private func deletionOverlay", notch_calendar)
        self.assertIn("setAutoCloseSuppression(active", notch_calendar)
        self.assertNotIn(".confirmationDialog(", notch_calendar)
        self.assertIn("deleteCalendarItem(id:", manager)
        self.assertIn("updateReminder(id:", manager)
        self.assertIn("updateEvent(id:", manager)
        self.assertIn("atollManagedCalendarItemCount", manager)
        self.assertIn("deleteAllAtollManagedCalendarItems()", manager)
        self.assertIn("showsBulkDeletionConfirmation", notch_calendar)
        self.assertIn('String(localized: "Clear All Atoll Items")', notch_calendar)
        self.assertIn("case restDay", (ROOT / "DynamicIsland" / "features" / "LiveEarnings" / "Calendar" / "WorkCalendarModels.swift").read_text())
        self.assertIn("func createEvent(title:", service)
        self.assertIn("func createReminder(title:", service)
        self.assertIn('URL(string: "atoll://work-calendar/event")', service)
        self.assertIn('URL(string: "atoll://work-calendar/todo")', service)
        registry = (
            ROOT / "DynamicIsland" / "features" / "LiveEarnings" / "Calendar" /
            "AtollCalendarItemRegistry.swift"
        ).read_text()
        self.assertIn("AtollManagedCalendarItem", registry)
        locations = (
            ROOT / "DynamicIsland" / "features" / "LiveEarnings" / "Calendar" /
            "WorkdayOverrideStore.swift"
        ).read_text()
        self.assertIn("calendar-items-v1.json", locations)


if __name__ == "__main__":
    unittest.main()
