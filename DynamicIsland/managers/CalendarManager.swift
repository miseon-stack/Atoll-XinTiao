/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var lockScreenEvents: [EventModel] = []
    @Published private(set) var workCalendarItemsByMonth: [LocalDate: [EventModel]] = [:]
    @Published private(set) var atollManagedCalendarItemCount = 0

    private var lockScreenPreviewEvents: [EventModel]?

    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()
    private let atollCalendarItemRegistry = AtollCalendarItemRegistry.shared
    private var lastEventsFetchDate: Date?
    private let reloadRefreshInterval: TimeInterval = 15
    private var eventStoreChangedObserver: NSObjectProtocol?
    private var pendingEventStoreRefreshTask: Task<Void, Never>?
    private var nextAllowedEventStoreRefresh: Date = .distantPast
    private var ignoreEventStoreChangesUntil: Date = .distantPast
    private let eventStoreChangeThrottle: TimeInterval = 20
    private let selfInducedChangeSuppression: TimeInterval = 6
    private let eventFetchLimiter = EventFetchLimiter()
    private var lastLockScreenEventsFetchDate: Date?
    private let lockScreenRefreshInterval: TimeInterval = 15
    private var lockScreenRefreshTask: Task<Void, Never>?

    var hasCalendarAccess: Bool { isAuthorized(calendarAuthorizationStatus) }
    var hasReminderAccess: Bool { isAuthorized(reminderAuthorizationStatus) }

    private init() {
        currentWeekStartDate = CalendarManager.startOfDay(Date())
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        setupEventStoreChangedObserver()
        startLockScreenRefreshLoop()
        Task {
            await reloadCalendarAndReminderLists()
            await preloadCurrentWorkCalendarMonthIfAuthorized()
            await refreshAtollManagedCalendarItemCount()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingEventStoreRefreshTask?.cancel()
        lockScreenRefreshTask?.cancel()
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleEventStoreChanged()
        }
    }

    private func handleEventStoreChanged() {
        Logger.log("CalendarManager: Event store changed notification received", category: .lifecycle)
        let now = Date()
        guard now >= ignoreEventStoreChangesUntil else { return }

        if now < nextAllowedEventStoreRefresh {
            let delay = max(nextAllowedEventStoreRefresh.timeIntervalSince(now), 0.05)
            scheduleEventStoreRefresh(after: delay)
            return
        }

        nextAllowedEventStoreRefresh = now.addingTimeInterval(eventStoreChangeThrottle)
        scheduleEventStoreRefresh(after: 0)
    }

    private func scheduleEventStoreRefresh(after delay: TimeInterval) {
        pendingEventStoreRefreshTask?.cancel()
        pendingEventStoreRefreshTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            await self.performEventStoreRefresh()
        }
    }

    @MainActor
    private func performEventStoreRefresh() async {
        pendingEventStoreRefreshTask = nil
        await reloadCalendarAndReminderLists()
        await maybeRefreshEventsAfterReload()
        await updateLockScreenEvents(force: true)
        nextAllowedEventStoreRefresh = Date().addingTimeInterval(eventStoreChangeThrottle)
        ignoreEventStoreChangesUntil = Date().addingTimeInterval(selfInducedChangeSuppression)
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let allCalendars = await calendarService.calendars()
        eventCalendars = allCalendars.filter { !$0.isReminder }
        reminderLists = allCalendars.filter { $0.isReminder }
        self.allCalendars = allCalendars
        updateSelectedCalendars()
    }

    @MainActor
    private func maybeRefreshEventsAfterReload() async {
        guard hasCalendarAccess else { return }
        let now = Date()
        if let lastFetch = lastEventsFetchDate, now.timeIntervalSince(lastFetch) < reloadRefreshInterval {
            return
        }
        await updateEvents()
    }

    private func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarAuthorizationStatus = status

        switch status {
        case .notDetermined:
            let granted = await calendarService.requestAccess(to: .event)
            calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                await updateEvents(force: true)
                await updateLockScreenEvents(force: true)
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .authorized, .fullAccess:
            await reloadCalendarAndReminderLists()
            await updateEvents(force: true)
            await updateLockScreenEvents(force: true)
        case .writeOnly:
            NSLog("Calendar write only")
        @unknown default:
            NSLog("Unknown calendar authorization status")
        }
    }

    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        reminderAuthorizationStatus = status

        switch status {
        case .notDetermined:
            let granted = await calendarService.requestAccess(to: .reminder)
            reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .authorized, .fullAccess:
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Reminder write only")
        @unknown default:
            NSLog("Unknown reminder authorization status")
        }
    }

    func updateSelectedCalendars() {
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }
        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            if identifiers.isEmpty || identifiers.count == allCalendars.count {
                selectionState = .all
            } else {
                selectionState = .selected(identifiers)
            }
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }

    /// Fetches calendar events and reminders for a visible month without
    /// replacing the selected day's `events` collection.
    func calendarItems(from startDate: Date, to endDate: Date) async -> [EventModel] {
        let service = calendarService
        let items = await eventFetchLimiter.run {
            // The work calendar must include items written to the system's
            // default calendar/reminder list, even when that list was granted
            // after Atoll's existing calendar selection was saved. An empty ID
            // filter intentionally means "all accessible calendars".
            await service.events(from: startDate, to: endDate, calendars: [])
        }
        workCalendarItemsByMonth[workCalendarMonthKey(for: startDate)] = items
        return items
    }

    func cachedWorkCalendarItems(for month: Date) -> [EventModel] {
        workCalendarItemsByMonth[workCalendarMonthKey(for: month)] ?? []
    }

    private func preloadCurrentWorkCalendarMonthIfAuthorized() async {
        guard hasCalendarAccess || hasReminderAccess else { return }
        let calendar = Calendar.autoupdatingCurrent
        let month = calendar.startOfMonth(containing: Date())
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: month) else { return }
        _ = await calendarItems(from: month, to: nextMonth)
    }

    private func workCalendarMonthKey(for date: Date) -> LocalDate {
        let calendar = Calendar.autoupdatingCurrent
        let month = calendar.startOfMonth(containing: date)
        return LocalDate(month, calendar: calendar)
    }

    /// Refreshes the privacy state before the standalone work calendar reads
    /// EventKit. Development builds are re-signed frequently, which can make
    /// macOS treat a newly installed build as an unapproved client even though
    /// the user's existing Calendar and Reminders data is still intact.
    func prepareWorkCalendarAccess() async {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        calendarAuthorizationStatus = eventStatus
        if eventStatus == .notDetermined {
            _ = await calendarService.requestAccess(to: .event)
            calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        }

        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        reminderAuthorizationStatus = reminderStatus
        if reminderStatus == .notDetermined {
            _ = await calendarService.requestAccess(to: .reminder)
            reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        }

        await reloadCalendarAndReminderLists()
    }

    func updateLockScreenEvents(force: Bool = false) async {
        if let previewEvents = lockScreenPreviewEvents {
            if lockScreenEvents != previewEvents {
                withAnimation(.smooth(duration: 0.25)) {
                    lockScreenEvents = previewEvents
                }
            }
            lastLockScreenEventsFetchDate = Date()
            return
        }

        let now = Date()

        if !force,
           let lastFetch = lastLockScreenEventsFetchDate,
           now.timeIntervalSince(lastFetch) < lockScreenRefreshInterval {
            return
        }

        let lookaheadRaw = Defaults[.lockScreenCalendarEventLookaheadWindow]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let isAllTimeLookahead =
            lookaheadRaw == "all_time" ||
            lookaheadRaw == "all time" ||
            lookaheadRaw == "alltime"

        let isRestOfDay =
            lookaheadRaw == "rest_of_day" ||
            lookaheadRaw == "rest of the day" ||
            lookaheadRaw == "restofday"

        func lookaheadMinutes(from raw: String) -> Int? {
            switch raw {
            case "15m", "15 min", "15 mins", "15min", "15mins": return 15
            case "30m", "30 min", "30 mins", "30min", "30mins": return 30
            case "1h", "1 hr", "1 hour", "1hour": return 60
            case "3h", "3 hr", "3 hours", "3hours": return 180
            case "6h", "6 hr", "6 hours", "6hours": return 360
            case "12h", "12 hr", "12 hours", "12hours": return 720
            default: return nil
            }
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday

        let endDate: Date
        if isAllTimeLookahead {
            endDate = calendar.date(byAdding: .day, value: 365, to: now) ?? now.addingTimeInterval(365 * 24 * 3600)
        } else if isRestOfDay {
            endDate = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(24 * 3600)
        } else if let minutes = lookaheadMinutes(from: lookaheadRaw) {
            endDate = calendar.date(byAdding: .minute, value: minutes, to: now) ?? now.addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            endDate = calendar.date(byAdding: .minute, value: 180, to: now) ?? now.addingTimeInterval(180 * 60)
        }

        let calendarIDs = allCalendars.map { $0.id }
        let service = calendarService

        let fetched = await eventFetchLimiter.run {
            await service.events(from: startDate, to: endDate, calendars: calendarIDs)
        }

        if lockScreenEvents == fetched {
            lastLockScreenEventsFetchDate = Date()
            return
        }

        withAnimation(.smooth(duration: 0.25)) {
            lockScreenEvents = fetched
        }
        lastLockScreenEventsFetchDate = Date()
    }

    func setLockScreenPreviewEvents(_ events: [EventModel]?) {
        lockScreenPreviewEvents = events
        guard let events else {
            Task { await updateLockScreenEvents(force: true) }
            return
        }
        withAnimation(.smooth(duration: 0.25)) {
            lockScreenEvents = events
        }
        lastLockScreenEventsFetchDate = Date()
    }

    private func startLockScreenRefreshLoop() {
        lockScreenRefreshTask?.cancel()
        lockScreenRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                guard self.hasCalendarAccess else { continue }
                await self.updateLockScreenEvents(force: false)
            }
        }
    }

    private func updateEvents(force: Bool = false) async {
        let now = Date()
        if !force, let lastFetch = lastEventsFetchDate, now.timeIntervalSince(lastFetch) < reloadRefreshInterval {
            return
        }
        
        Logger.log("CalendarManager: Updating events (force: \(force))", category: .lifecycle)

        let calendarIDs = selectedCalendars.map { $0.id }
        let startDate = currentWeekStartDate
        guard let endDate = Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate) else { return }
        let service = calendarService

        let events = await eventFetchLimiter.run {
            await service.events(
                from: startDate,
                to: endDate,
                calendars: calendarIDs
            )
        }

        self.events = events
        lastEventsFetchDate = Date()
    }

    func setCalendarsSelected(_ calendars: [CalendarModel], isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]
        let ids = Set(calendars.map { $0.id })

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting(ids)
                selectionState = .selected(identifiers)
            }
        case .selected(var identifiers):
            if isSelected {
                identifiers.formUnion(ids)
            } else {
                identifiers.subtract(ids)
            }

            if identifiers.isEmpty || identifiers.count == allCalendars.count {
                selectionState = .all
            } else {
                selectionState = .selected(identifiers)
            }
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        await updateEvents(force: true)
    }

    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws {
        await checkCalendarAuthorization()
        guard hasCalendarAccess else { throw CalendarItemCreationError.eventsAccessRequired }
        let id = try await calendarService.createEvent(title: title, start: start, end: end, isAllDay: isAllDay)
        do {
            try await atollCalendarItemRegistry.insert(id: id, isReminder: false)
        } catch {
            try? await calendarService.deleteCalendarItem(id: id, isReminder: false)
            throw error
        }
        await refreshAtollManagedCalendarItemCount()
        ignoreEventStoreChangesUntil = Date().addingTimeInterval(selfInducedChangeSuppression)
        await reloadCalendarAndReminderLists()
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }

    func createReminder(title: String, due: Date) async throws {
        await checkReminderAuthorization()
        guard hasReminderAccess else { throw CalendarItemCreationError.remindersAccessRequired }
        let id = try await calendarService.createReminder(title: title, due: due)
        do {
            try await atollCalendarItemRegistry.insert(id: id, isReminder: true)
        } catch {
            try? await calendarService.deleteCalendarItem(id: id, isReminder: true)
            throw error
        }
        await refreshAtollManagedCalendarItemCount()
        ignoreEventStoreChangesUntil = Date().addingTimeInterval(selfInducedChangeSuppression)
        await reloadCalendarAndReminderLists()
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }

    func updateEvent(id: String, title: String, start: Date, end: Date, isAllDay: Bool) async throws {
        try await calendarService.updateEvent(id: id, title: title, start: start, end: end, isAllDay: isAllDay)
        await refreshAfterCalendarMutation()
    }

    func updateReminder(id: String, title: String, due: Date) async throws {
        try await calendarService.updateReminder(id: id, title: title, due: due)
        await refreshAfterCalendarMutation()
    }

    func deleteCalendarItem(id: String, isReminder: Bool) async throws {
        try await calendarService.deleteCalendarItem(id: id, isReminder: isReminder)
        try? await atollCalendarItemRegistry.remove(id: id)
        await refreshAtollManagedCalendarItemCount()
        await refreshAfterCalendarMutation()
    }

    func deleteAllAtollManagedCalendarItems() async -> (deleted: Int, failed: Int) {
        let registeredItems = (try? await atollCalendarItemRegistry.all()) ?? []
        var resolvedIDs = Set<String>()
        var deleted = 0
        var failed = 0

        for item in registeredItems {
            do {
                try await calendarService.deleteCalendarItem(id: item.id, isReminder: item.isReminder)
                resolvedIDs.insert(item.id)
                deleted += 1
            } catch CalendarItemCreationError.itemNotFound {
                // A user may have already removed the system item outside Atoll.
                // Treat the stale registry entry as resolved.
                resolvedIDs.insert(item.id)
            } catch {
                failed += 1
            }
        }

        try? await atollCalendarItemRegistry.remove(ids: resolvedIDs)
        await refreshAtollManagedCalendarItemCount()
        workCalendarItemsByMonth.removeAll()
        await refreshAfterCalendarMutation()
        return (deleted, failed)
    }

    private func refreshAtollManagedCalendarItemCount() async {
        atollManagedCalendarItemCount = (try? await atollCalendarItemRegistry.all().count) ?? 0
    }

    private func refreshAfterCalendarMutation() async {
        ignoreEventStoreChangesUntil = Date().addingTimeInterval(selfInducedChangeSuppression)
        await reloadCalendarAndReminderLists()
        await updateEvents(force: true)
        await updateLockScreenEvents(force: true)
    }
}

// MARK: - Event Fetch Limiter

private actor EventFetchLimiter {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isRunning = false

    func run<T>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await waitTurn()
        defer { resumeNext() }
        return await operation()
    }

    private func waitTurn() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeNext() {
        if waiters.isEmpty {
            isRunning = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
