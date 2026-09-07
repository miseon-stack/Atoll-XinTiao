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

import Foundation
import EventKit

protocol CalendarServiceProviding {
    func requestAccess() async -> Bool
    func requestAccess(to type: EKEntityType) async -> Bool
    func calendars() async -> [CalendarModel]
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel]
    func setReminderCompleted(reminderID: String, completed: Bool) async
    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws -> String
    func createReminder(title: String, due: Date) async throws -> String
    func updateEvent(id: String, title: String, start: Date, end: Date, isAllDay: Bool) async throws
    func updateReminder(id: String, title: String, due: Date) async throws
    func deleteCalendarItem(id: String, isReminder: Bool) async throws
}

class CalendarService: CalendarServiceProviding {
    private let store = EKEventStore()
    
    @MainActor
    func requestAccess() async -> Bool {
        let eventsAccess = await requestAccess(to: .event)
        let remindersAccess = await requestAccess(to: .reminder)
        return eventsAccess || remindersAccess
    }

    @MainActor
    func requestAccess(to type: EKEntityType) async -> Bool {
        do {
            return try await performAccessRequest(for: type)
        } catch {
            print("Calendar access error: \(error)")
            return false
        }
    }

    private func performAccessRequest(for type: EKEntityType) async throws -> Bool {
        switch type {
        case .event:
            return try await store.requestFullAccessToEvents()
        case .reminder:
            return try await store.requestFullAccessToReminders()
        @unknown default:
            return false
        }
    }
    
    private func hasAccess(to entityType: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: entityType)
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }
    
    func calendars() async -> [CalendarModel] {
        var calendars: [EKCalendar] = []
        
        for type in [EKEntityType.event, .reminder] where hasAccess(to: type) {
            calendars.append(contentsOf: store.calendars(for: type))
        }
        
        return calendars.map { CalendarModel(from: $0) }
    }
    
    func events(from start: Date, to end: Date, calendars ids: [String]) async -> [EventModel] {
        let allCalendars = await self.calendars()
        let filteredCalendars = allCalendars.filter { ids.isEmpty || ids.contains($0.id) }
        let ekCalendars = filteredCalendars.compactMap { calendarModel in
            store.calendars(for: .event).first { $0.calendarIdentifier == calendarModel.id } ??
            store.calendars(for: .reminder).first { $0.calendarIdentifier == calendarModel.id }
        }
        
        var events: [EventModel] = []
        
        // Fetch regular events
        if hasAccess(to: .event) {
            let eventCalendars = ekCalendars.filter { store.calendars(for: .event).contains($0) }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: eventCalendars)
            let ekEvents = store.events(matching: predicate)
            events.append(contentsOf: ekEvents.compactMap { EventModel(from: $0) })
        }
        
        // Fetch reminders
        if hasAccess(to: .reminder) {
            let reminderCalendars = ekCalendars.filter { store.calendars(for: .reminder).contains($0) }
            events.append(contentsOf: await fetchReminders(from: start, to: end, calendars: reminderCalendars))
        }
        
        return events.sorted { $0.start < $1.start }
    }
    
    private func fetchReminders(from start: Date, to end: Date, calendars: [EKCalendar]) async -> [EventModel] {
        guard !calendars.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: calendars)
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(returning: [])
                    return
                }

                let filtered = reminders.compactMap { reminder -> EventModel? in
                    guard let dueDate = reminder.dueDateComponents?.date,
                          dueDate >= start,
                          dueDate <= end else {
                        return nil
                    }
                    return EventModel(from: reminder)
                }

                continuation.resume(returning: filtered)
            }
        }
    }

    @MainActor
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            print("Failed to update reminder completion: \(error)")
        }
    }

    @MainActor
    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws -> String {
        guard hasAccess(to: .event) else { throw CalendarItemCreationError.eventsAccessRequired }
        guard let calendar = store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first(where: \.allowsContentModifications) else {
            throw CalendarItemCreationError.noWritableCalendar
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = calendar
        event.url = URL(string: "atoll://work-calendar/event")
        event.isAllDay = isAllDay
        if isAllDay {
            event.startDate = Calendar.current.startOfDay(for: start)
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate) ?? end
        } else {
            event.startDate = start
            event.endDate = max(end, start.addingTimeInterval(60))
        }
        try store.save(event, span: .thisEvent, commit: true)
        return event.calendarItemIdentifier
    }

    @MainActor
    func createReminder(title: String, due: Date) async throws -> String {
        guard hasAccess(to: .reminder) else { throw CalendarItemCreationError.remindersAccessRequired }
        guard let calendar = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first(where: \.allowsContentModifications) else {
            throw CalendarItemCreationError.noWritableReminderList
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        reminder.url = URL(string: "atoll://work-calendar/todo")
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: due
        )
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    @MainActor
    func updateEvent(id: String, title: String, start: Date, end: Date, isAllDay: Bool) async throws {
        guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
            throw CalendarItemCreationError.itemNotFound
        }
        event.title = title
        event.isAllDay = isAllDay
        if isAllDay {
            event.startDate = Calendar.current.startOfDay(for: start)
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate) ?? end
        } else {
            event.startDate = start
            event.endDate = max(end, start.addingTimeInterval(60))
        }
        try store.save(event, span: .thisEvent, commit: true)
    }

    @MainActor
    func updateReminder(id: String, title: String, due: Date) async throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CalendarItemCreationError.itemNotFound
        }
        reminder.title = title
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: due
        )
        try store.save(reminder, commit: true)
    }

    @MainActor
    func deleteCalendarItem(id: String, isReminder: Bool) async throws {
        if isReminder {
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw CalendarItemCreationError.itemNotFound
            }
            try store.remove(reminder, commit: true)
        } else {
            guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
                throw CalendarItemCreationError.itemNotFound
            }
            try store.remove(event, span: .thisEvent, commit: true)
        }
    }
}

enum CalendarItemCreationError: LocalizedError {
    case eventsAccessRequired
    case remindersAccessRequired
    case noWritableCalendar
    case noWritableReminderList
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .eventsAccessRequired: String(localized: "Calendar access is required to create events.")
        case .remindersAccessRequired: String(localized: "Reminders access is required to create to-dos.")
        case .noWritableCalendar: String(localized: "No writable calendar is available.")
        case .noWritableReminderList: String(localized: "No writable reminder list is available.")
        case .itemNotFound: String(localized: "The calendar item no longer exists.")
        }
    }
}

// MARK: - Model Extensions

extension CalendarModel {
    init(from calendar: EKCalendar) {
        self.init(
            accountName: calendar.accountTitle,
            id: calendar.calendarIdentifier,
            title: calendar.title,
            color: calendar.color,
            isSubscribed: calendar.isSubscribed || calendar.isDelegate,
            isReminder: calendar.allowedEntityTypes.contains(.reminder)
        )
    }
}

extension EventModel {
    init?(from event: EKEvent) {
        guard let calendar = event.calendar else { return nil }
        
        self.init(
            id: event.calendarItemIdentifier,
            start: event.startDate,
            end: event.endDate,
            title: event.title ?? "",
            location: event.location,
            notes: event.notes,
            url: event.url,
            isAllDay: event.shouldBeAllDay,
            type: .init(from: event),
            calendar: .init(from: calendar),
            participants: .init(from: event),
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : event.timeZone,
            hasRecurrenceRules: event.hasRecurrenceRules || event.isDetached,
            priority: nil,
            conferenceURL: event.extractConferenceURL()
        )
    }
    
    init?(from reminder: EKReminder) {
        guard let calendar = reminder.calendar,
              let dueDateComponents = reminder.dueDateComponents,
              let date = Calendar.current.date(from: dueDateComponents)
        else { return nil }
        
        self.init(
            id: reminder.calendarItemIdentifier,
            start: date,
            end: Calendar.current.endOfDay(for: date),
            title: reminder.title ?? "",
            location: reminder.location,
            notes: reminder.notes,
            url: reminder.url,
            isAllDay: dueDateComponents.hour == nil,
            type: .reminder(completed: reminder.isCompleted),
            calendar: .init(from: calendar),
            participants: [],
            timeZone: calendar.isSubscribed || calendar.isDelegate ? nil : reminder.timeZone,
            hasRecurrenceRules: reminder.hasRecurrenceRules,
            priority: .init(from: reminder.priority),
            conferenceURL: nil
        )
    }
}

extension EventType {
    init(from event: EKEvent) {
        self = event.birthdayContactIdentifier != nil ? .birthday : .event(.init(from: event.currentUser?.participantStatus))
    }
}

extension AttendanceStatus {
    init(from status: EKParticipantStatus?) {
        switch status {
        case .accepted:
            self = .accepted
        case .tentative:
            self = .maybe
        case .declined:
            self = .declined
        case .pending:
            self = .pending
        default:
            self = .unknown
        }
    }
}

extension Array where Element == Participant {
    init(from event: EKEvent) {
        var participants = event.attendees ?? []
        if let organizer = event.organizer, !participants.contains(where: { $0.url == organizer.url }) {
            participants.append(organizer)
        }
        self.init(
            participants.map { .init(from: $0, isOrganizer: $0.url == event.organizer?.url) }
        )
    }
}

extension Participant {
    init(from participant: EKParticipant, isOrganizer: Bool) {
        self.init(
            name: participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
            status: .init(from: participant.participantStatus),
            isOrganizer: isOrganizer,
            isCurrentUser: participant.isCurrentUser
        )
    }
}

extension Priority {
    init?(from p: Int) {
        switch p {
        case 1...4:
            self = .high
        case 5:
            self = .medium
        case 6...9:
            self = .low
        default:
            return nil
        }
    }
}

// MARK: - Helper Extensions

extension EKCalendar {
    var accountTitle: String {
        switch source.sourceType {
        case .local, .subscribed, .birthdays:
            return String(localized: "Other")
        default:
            return source.title
        }
    }
    
    var isDelegate: Bool {
        return source.isDelegate
    }
}

private extension EKEvent {
    var currentUser: EKParticipant? {
        attendees?.first(where: \.isCurrentUser)
    }
    
    var shouldBeAllDay: Bool {
        guard !isAllDay else { return true }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: startDate)
        let endOfDay = calendar.dateInterval(of: .day, for: endDate)?.end
        return startDate == startOfDay && endDate == endOfDay
    }
    
    /// Extract conference call URL from various sources
    func extractConferenceURL() -> URL? {
        // First try the URL field if it's a conference URL
        if let eventURL = url, isConferenceURL(eventURL) {
            return eventURL
        }
        
        // Then try to extract from location field
        if let location = location, let conferenceURL = extractURLFromText(location) {
            return conferenceURL
        }
        
        // Finally try to extract from notes
        if let notes = notes, let conferenceURL = extractURLFromText(notes) {
            return conferenceURL
        }
        
        return nil
    }
    
    /// Check if a URL is likely a conference URL
    private func isConferenceURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let conferenceHosts = [
            "zoom.us",
            "teams.microsoft.com",
            "meet.google.com",
            "webex.com",
            "gotomeeting.com",
            "bluejeans.com",
            "whereby.com",
            "meet.jit.si",
            "discord.gg",
            "discord.com",
            "facetime.apple.com"
        ]
        
        return conferenceHosts.contains { host.contains($0) }
    }
    
    /// Extract first valid conference URL from text
    private func extractURLFromText(_ text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        
        for match in matches ?? [] {
            if let url = match.url, isConferenceURL(url) {
                return url
            }
        }
        
        return nil
    }
}

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        dateInterval(of: .day, for: date)?.end ?? date
    }
}
