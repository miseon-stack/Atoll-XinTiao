/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import SwiftUI

struct WorkCalendarView: View {
    @ObservedObject private var controller = LiveEarningsController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var displayedMonth = Calendar.autoupdatingCurrent.startOfMonth(containing: Date())
    @State private var selectedDate = Date()
    @State private var customSchedule = LiveEarningsSchedule(config: LiveEarningsController.shared.config)
    @State private var errorMessage: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(String(localized: "Work Calendar"))
                    .font(.title2.bold())
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
            }

            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(displayedMonth.formatted(.dateTime.year().month(.wide)))
                    .font(.headline)
                Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
            }

            if !controller.isHolidayYearCovered(Calendar.autoupdatingCurrent.component(.year, from: displayedMonth)) {
                Label(
                    String(localized: "Official calendar unavailable for this year. Recurring workdays will be used."),
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            calendarGrid

            Divider()
            selectedDayEditor

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 670)
        .onAppear { loadSelection() }
        .onChange(of: selectedDate) { _, _ in loadSelection() }
    }

    private var calendarGrid: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(daySlots.enumerated()), id: \.offset) { _, day in
                    if let day {
                        WorkCalendarDayCell(
                            date: day,
                            schedule: controller.resolvedSchedule(on: day),
                            holidayName: controller.holidayRule(on: day)?.name,
                            isSelected: Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: selectedDate)
                        ) {
                            selectedDate = day
                        }
                    } else {
                        Color.clear.frame(height: 54)
                    }
                }
            }
        }
    }

    private var selectedDayEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedDate.formatted(date: .complete, time: .omitted)).font(.headline)
                    Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if hasOverride {
                    Button(String(localized: "Restore Automatic"), role: .destructive) {
                        Task { await removeOverride() }
                    }
                }
            }

            HStack {
                Button(String(localized: "Leave Day")) { Task { await save(.leaveDay) } }
                Button(String(localized: "Temporary Workday")) { Task { await save(.temporaryWorkday) } }
                Button(String(localized: "Rest Day")) { Task { await save(.restDay) } }
                Button(String(localized: "Public Holiday")) { Task { await save(.publicHoliday) } }
                Button(String(localized: "Custom Schedule")) { Task { await save(.customSchedule) } }
            }
            .buttonStyle(.bordered)

            GroupBox(String(localized: "Single-day schedule")) {
                VStack(spacing: 10) {
                    HStack {
                        DatePicker(String(localized: "Start"), selection: timeBinding(\.workStart), displayedComponents: .hourAndMinute)
                        DatePicker(String(localized: "End"), selection: timeBinding(\.workEnd), displayedComponents: .hourAndMinute)
                    }
                    Toggle(String(localized: "Pause during lunch"), isOn: $customSchedule.lunchBreakEnabled)
                    if customSchedule.lunchBreakEnabled {
                        HStack {
                            DatePicker(String(localized: "Lunch start"), selection: timeBinding(\.lunchStart), displayedComponents: .hourAndMinute)
                            DatePicker(String(localized: "Lunch end"), selection: timeBinding(\.lunchEnd), displayedComponents: .hourAndMinute)
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private var daySlots: [Date?] {
        let calendar = Calendar.autoupdatingCurrent
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let blanks: [Date?] = Array(repeating: nil, count: leading)
        return blanks + range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: displayedMonth)
        }.map(Optional.some)
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.autoupdatingCurrent
        let symbols = DateFormatter().veryShortWeekdaySymbols ?? []
        guard !symbols.isEmpty else { return [] }
        let offset = max(0, calendar.firstWeekday - 1)
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    private var selectedLocalDate: LocalDate { LocalDate(selectedDate, calendar: .autoupdatingCurrent) }
    private var hasOverride: Bool { controller.workdayOverrides[selectedLocalDate] != nil }

    private var sourceDescription: String {
        if let item = controller.workdayOverrides[selectedLocalDate] {
            switch item.kind {
            case .leaveDay: return String(localized: "Manual override · Leave day")
            case .temporaryWorkday: return String(localized: "Manual override · Temporary workday")
            case .customSchedule: return String(localized: "Manual override · Custom schedule")
            case .restDay: return String(localized: "Manual override · Rest day")
            case .publicHoliday: return String(localized: "Manual override · Public holiday")
            }
        }
        if let holiday = controller.holidayRule(on: selectedDate) {
            return holiday.kind == .publicHoliday
                ? String(localized: "Official calendar · \(holiday.name) holiday")
                : String(localized: "Official calendar · \(holiday.name)")
        }
        let schedule = controller.resolvedSchedule(on: selectedDate)
        return schedule.isWorkday ? String(localized: "Recurring workday") : String(localized: "Recurring rest day")
    }

    private func loadSelection() {
        if let schedule = controller.workdayOverrides[selectedLocalDate]?.schedule {
            customSchedule = schedule
        } else {
            customSchedule = LiveEarningsSchedule(config: controller.config)
        }
    }

    private func save(_ kind: WorkdayOverrideKind) async {
        do {
            let schedule = kind == .customSchedule ? customSchedule : nil
            try await controller.setOverride(on: selectedDate, kind: kind, schedule: schedule)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeOverride() async {
        do {
            try await controller.removeOverride(on: selectedDate)
            errorMessage = nil
            loadSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveMonth(_ offset: Int) {
        guard let next = Calendar.autoupdatingCurrent.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        displayedMonth = next
        selectedDate = next
    }

    private func timeBinding(_ keyPath: WritableKeyPath<LiveEarningsSchedule, LiveEarningsLocalTime>) -> Binding<Date> {
        Binding {
            let value = customSchedule[keyPath: keyPath]
            return Calendar.autoupdatingCurrent.date(bySettingHour: value.hour, minute: value.minute, second: 0, of: selectedDate) ?? selectedDate
        } set: { value in
            let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: value)
            customSchedule[keyPath: keyPath] = .init(hour: components.hour ?? 0, minute: components.minute ?? 0)
        }
    }
}

private struct WorkCalendarDayCell: View {
    let date: Date
    let schedule: EffectiveWorkSchedule
    let holidayName: String?
    let isSelected: Bool
    let eventCount: Int
    let todoCount: Int
    let action: () -> Void
    let doubleAction: (() -> Void)?

    init(
        date: Date,
        schedule: EffectiveWorkSchedule,
        holidayName: String?,
        isSelected: Bool,
        eventCount: Int = 0,
        todoCount: Int = 0,
        action: @escaping () -> Void,
        doubleAction: (() -> Void)? = nil
    ) {
        self.date = date
        self.schedule = schedule
        self.holidayName = holidayName
        self.isSelected = isSelected
        self.eventCount = eventCount
        self.todoCount = todoCount
        self.action = action
        self.doubleAction = doubleAction
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text("\(Calendar.autoupdatingCurrent.component(.day, from: date))")
                    .font(.body.weight(.semibold))
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(badgeColor)
                    .lineLimit(1)

                calendarItemIndicators
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(isSelected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                doubleAction?()
            }
        )
        .help(holidayName ?? badge)
    }

    @ViewBuilder
    private var calendarItemIndicators: some View {
        if eventCount > 0 || todoCount > 0 {
            HStack(spacing: 4) {
                if eventCount > 0 {
                    calendarItemBadge(systemImage: "calendar", count: eventCount, color: .blue)
                }
                if todoCount > 0 {
                    calendarItemBadge(systemImage: "checkmark.circle.fill", count: todoCount, color: .orange)
                }
            }
            .frame(height: 16)
        } else {
            // Reserve the same third line for every day so rows remain aligned
            // when only some dates contain events or to-dos.
            Color.clear.frame(height: 16)
        }
    }

    private func calendarItemBadge(systemImage: String, count: Int, color: Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: systemImage)
            Text("\(count)")
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(color.opacity(0.18), in: Capsule())
    }

    private var badge: String {
        switch schedule.status {
        case .publicHoliday: return String(localized: "Holiday")
        case .leaveDay: return String(localized: "Leave")
        case .restDay: return String(localized: "Rest")
        case .workday:
            return schedule.source == .makeupWorkday ? String(localized: "Makeup")
                : schedule.source == .userOverride ? String(localized: "Temporary")
                : String(localized: "Work")
        }
    }

    private var badgeColor: Color {
        switch schedule.status {
        case .workday: .green
        case .publicHoliday: .orange
        case .leaveDay: .pink
        case .restDay: .secondary
        }
    }
}

extension Calendar {
    func startOfMonth(containing date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

// MARK: - Standalone notch calendar

private enum CalendarCreationKind: String, CaseIterable, Identifiable {
    case event
    case todo

    var id: Self { self }
    var title: String {
        switch self {
        case .event: String(localized: "Event")
        case .todo: String(localized: "To-Do")
        }
    }
}

struct NotchWorkCalendarView: View {
    @EnvironmentObject private var viewModel: DynamicIslandViewModel
    @ObservedObject private var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject private var controller = LiveEarningsController.shared
    @ObservedObject private var calendarManager = CalendarManager.shared

    @State private var displayedMonth = Calendar.autoupdatingCurrent.startOfMonth(containing: Date())
    @State private var selectedDate = Date()
    @State private var customSchedule = LiveEarningsSchedule(config: LiveEarningsController.shared.config)
    @State private var creationKind: CalendarCreationKind = .todo
    @State private var itemTitle = ""
    @State private var itemStart = Date()
    @State private var itemEnd = Date().addingTimeInterval(3600)
    @State private var itemIsAllDay = false
    @State private var showsCreationEditor = false
    @State private var showsDayItemsOverlay = false
    @State private var editingItem: EventModel?
    @State private var itemPendingDeletion: EventModel?
    @State private var showsBulkDeletionConfirmation = false
    @State private var isDeletingAllAtollItems = false
    @State private var isSaving = false
    @State private var message: String?
    @State private var autoCloseSuppressionToken = UUID()

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(String(localized: "Work Calendar"))
                    .font(.title2.bold())
                Spacer()
                Button(role: .destructive) {
                    showsBulkDeletionConfirmation = true
                } label: {
                    Label(String(localized: "Clear All Atoll Items"), systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(calendarManager.atollManagedCalendarItemCount == 0)
                .help(String(localized: "Only items created by Atoll are deleted."))
                Button(String(localized: "Done")) {
                    coordinator.currentView = .home
                }
            }

            // Keep the complete month outside the scrolling editor. SwiftUI can
            // otherwise compress a lazy grid to one visible row inside the notch.
            monthPane
                .frame(maxWidth: .infinity)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                dayPane
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .overlay {
            calendarManagementOverlay
        }
        .onAppear { selectToday() }
        .task {
            // Let the tab's slide transition complete before EventKit performs
            // its first potentially blocking store read.
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            await loadCalendarContent()
        }
        .onChange(of: selectedDate) { _, newDate in
            displayedMonth = calendar.startOfMonth(containing: newDate)
            loadSelection()
            resetCreationTimes(for: newDate)
        }
        .onChange(of: displayedMonth) { _, newMonth in
            Task { await refreshMonthItems(for: newMonth) }
        }
        .onChange(of: viewModel.notchState) { _, state in
            guard state == .open else { return }
            Task {
                await refreshMonthItems(for: displayedMonth)
            }
        }
        .onChange(of: hasActiveCalendarOverlay) { _, active in
            updateAutoCloseSuppression(active)
        }
        .onDisappear {
            viewModel.setAutoCloseSuppression(false, token: autoCloseSuppressionToken)
        }
    }

    private var monthPane: some View {
        VStack(spacing: 8) {
            HStack {
                Button { moveMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(displayedMonth.formatted(.dateTime.year().month(.wide)))
                    .font(.headline)
                Spacer()
                Button { moveMonth(1) } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Label(
                    selectedDate.formatted(.dateTime.month().day().weekday(.abbreviated)),
                    systemImage: "calendar"
                )
                .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    beginCreation(.event)
                } label: {
                    Label(String(localized: "Add Event"), systemImage: "calendar.badge.plus")
                }
                Button {
                    beginCreation(.todo)
                } label: {
                    Label(String(localized: "Add To-Do"), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                ForEach(Array(calendarRows.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 6) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            if let day {
                                let items = monthItemsByDay[LocalDate(day, calendar: calendar)] ?? []
                                WorkCalendarDayCell(
                                    date: day,
                                    schedule: controller.resolvedSchedule(on: day),
                                    holidayName: controller.holidayRule(on: day)?.name,
                                    isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
                                    eventCount: items.filter { !$0.type.isReminder }.count,
                                    todoCount: items.filter { $0.type.isReminder }.count
                                ) {
                                    selectedDate = day
                                } doubleAction: {
                                    selectedDate = day
                                    showsDayItemsOverlay = true
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity, minHeight: 66)
                            }
                        }
                    }
                }
            }

            if !controller.isHolidayYearCovered(calendar.component(.year, from: displayedMonth)) {
                Label(
                    String(localized: "Official calendar unavailable for this year. Recurring workdays will be used."),
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dayPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedDate.formatted(date: .complete, time: .omitted))
                        .font(.headline)
                    Text(sourceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedOverride != nil {
                    Button(String(localized: "Restore Automatic"), role: .destructive) {
                        Task { await restoreAutomatic() }
                    }
                }
            }

            HStack {
                Button(String(localized: "Leave Day")) {
                    Task { await saveOverride(.leaveDay) }
                }
                Button(String(localized: "Temporary Workday")) {
                    Task { await saveOverride(.temporaryWorkday) }
                }
                Button(String(localized: "Custom Schedule")) {
                    Task { await saveOverride(.customSchedule) }
                }
                .disabled(!customSchedule.isValid)

                Menu {
                    Button(String(localized: "Automatic")) { Task { await restoreAutomatic() } }
                    Divider()
                    Button(String(localized: "Rest Day")) { Task { await saveOverride(.restDay) } }
                    Button(String(localized: "Public Holiday")) { Task { await saveOverride(.publicHoliday) } }
                } label: {
                    Label(String(localized: "Set Day Type"), systemImage: "slider.horizontal.3")
                }
            }
            .buttonStyle(.bordered)

            scheduleEditor

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "Schedule & To-Dos"), systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))

                if selectedDayItems.isEmpty {
                    Text(String(localized: "No events or to-dos for this day."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedDayItems.prefix(3)) { event in
                        calendarItemRow(event)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(message == String(localized: "Saved") ? .green : .orange)
            }
        }
    }

    private var scheduleEditor: some View {
        GroupBox(String(localized: "Single-day schedule")) {
            VStack(spacing: 10) {
                HStack {
                    DatePicker(String(localized: "Start"), selection: timeBinding(\.workStart), displayedComponents: .hourAndMinute)
                    DatePicker(String(localized: "End"), selection: timeBinding(\.workEnd), displayedComponents: .hourAndMinute)
                }
                Toggle(String(localized: "Pause during lunch"), isOn: $customSchedule.lunchBreakEnabled)
                if customSchedule.lunchBreakEnabled {
                    HStack {
                        DatePicker(String(localized: "Lunch start"), selection: timeBinding(\.lunchStart), displayedComponents: .hourAndMinute)
                        DatePicker(String(localized: "Lunch end"), selection: timeBinding(\.lunchEnd), displayedComponents: .hourAndMinute)
                    }
                }
            }
            .padding(6)
        }
    }

    private var creationEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $creationKind) {
                    ForEach(CalendarCreationKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(editingItem != nil)
                TextField(String(localized: "Title"), text: $itemTitle)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Cancel")) {
                    dismissCreationEditor()
                }
            }

            if creationKind == .event {
                Toggle(String(localized: "All-day"), isOn: $itemIsAllDay)
                    .font(.caption)
                if !itemIsAllDay {
                    HStack {
                        DatePicker(String(localized: "Start"), selection: $itemStart, displayedComponents: .hourAndMinute)
                        DatePicker(String(localized: "End"), selection: $itemEnd, displayedComponents: .hourAndMinute)
                    }
                }
            } else {
                DatePicker(String(localized: "Due"), selection: $itemStart, displayedComponents: .hourAndMinute)
            }

            Button {
                Task { await createItem() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        editingItem == nil ? String(localized: "Add") : String(localized: "Save"),
                        systemImage: editingItem == nil ? "plus" : "checkmark"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(itemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
        }
        .padding(9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var calendarManagementOverlay: some View {
        if showsBulkDeletionConfirmation {
            bulkDeletionOverlay
        } else if let itemPendingDeletion {
            deletionOverlay(itemPendingDeletion)
        } else if showsCreationEditor {
            creationOverlay
        } else if showsDayItemsOverlay {
            dayItemsOverlay
        }
    }

    private var hasActiveCalendarOverlay: Bool {
        showsBulkDeletionConfirmation || showsCreationEditor || showsDayItemsOverlay || itemPendingDeletion != nil
    }

    @ViewBuilder
    private var creationOverlay: some View {
        if showsCreationEditor {
            ZStack {
                Color.black.opacity(0.58)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissCreationEditor()
                    }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(editorTitle)
                                .font(.headline)
                            Text(selectedDate.formatted(date: .complete, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            dismissCreationEditor()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }

                    creationEditor
                }
                .padding(16)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .zIndex(20)
        }
    }

    private var dayItemsOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)
                .contentShape(Rectangle())
                .onTapGesture { showsDayItemsOverlay = false }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Schedule & To-Dos"))
                            .font(.headline)
                        Text(selectedDate.formatted(date: .complete, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        beginCreation(.event)
                    } label: {
                        Label(String(localized: "Add Event"), systemImage: "calendar.badge.plus")
                    }
                    .controlSize(.small)
                    Button {
                        beginCreation(.todo)
                    } label: {
                        Label(String(localized: "Add To-Do"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        showsDayItemsOverlay = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        if selectedDayItems.isEmpty {
                            ContentUnavailableView(
                                String(localized: "No events or to-dos for this day."),
                                systemImage: "calendar.badge.plus"
                            )
                            .frame(maxWidth: .infinity, minHeight: 150)
                        } else {
                            ForEach(selectedDayItems) { item in
                                calendarItemRow(item)
                                    .padding(9)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .padding(16)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(20)
    }

    private func deletionOverlay(_ item: EventModel) -> some View {
        ZStack {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 14) {
                Label(String(localized: "Delete this item?"), systemImage: "trash")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(item.title.isEmpty ? String(localized: "Untitled") : item.title)
                    .font(.body.weight(.semibold))
                Text(item.start.formatted(date: .complete, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) {
                        itemPendingDeletion = nil
                    }
                    Button(String(localized: "Delete"), role: .destructive) {
                        Task { await deleteItem(item) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(18)
            .frame(maxWidth: 430)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(30)
    }

    private var bulkDeletionOverlay: some View {
        ZStack {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 14) {
                Label(String(localized: "Clear all Atoll events and to-dos?"), systemImage: "trash")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "This will delete %lld items created by Atoll."),
                        calendarManager.atollManagedCalendarItemCount
                    )
                )
                Text(String(localized: "Your existing macOS Calendar and Reminders data will not be affected."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) {
                        showsBulkDeletionConfirmation = false
                    }
                    .disabled(isDeletingAllAtollItems)
                    Button(String(localized: "Delete All"), role: .destructive) {
                        Task { await deleteAllAtollItems() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isDeletingAllAtollItems)
                }
            }
            .padding(18)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(30)
    }

    private func calendarItemRow(_ event: EventModel) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(eventColor(event))
                .frame(width: 7, height: 7)
            Image(systemName: event.type.isReminder ? "checkmark.circle" : "calendar")
                .foregroundStyle(.secondary)
            Text(event.title.isEmpty ? String(localized: "Untitled") : event.title)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(reminderCompleted(event))
            Spacer()
            Text(eventTime(event))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if event.type.isReminder {
                Button {
                    Task { await toggleReminderCompletion(event) }
                } label: {
                    Image(systemName: reminderCompleted(event) ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .help(reminderCompleted(event)
                    ? String(localized: "Mark Incomplete")
                    : String(localized: "Mark Complete"))
            }
            Button {
                beginEditing(event)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help(String(localized: "Edit"))
            Button(role: .destructive) {
                itemPendingDeletion = event
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete"))
        }
    }

    private var daySlots: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: displayedMonth)
        }.map(Optional.some)
    }

    private var calendarRows: [[Date?]] {
        var slots = daySlots
        // Always reserve six weeks (42 cells). Months with only four or five
        // visible weeks keep empty rows, so the editor starts at the exact same
        // vertical position when switching months.
        slots.append(contentsOf: Array(repeating: nil, count: max(0, 42 - slots.count)))
        return stride(from: 0, to: slots.count, by: 7).map { start in
            Array(slots[start..<min(start + 7, slots.count)])
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = DateFormatter().veryShortWeekdaySymbols ?? []
        guard !symbols.isEmpty else { return [] }
        let offset = max(0, calendar.firstWeekday - 1)
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    private var selectedLocalDate: LocalDate { LocalDate(selectedDate, calendar: calendar) }
    private var monthItemsByDay: [LocalDate: [EventModel]] {
        Dictionary(grouping: calendarManager.cachedWorkCalendarItems(for: displayedMonth)) { item in
            LocalDate(item.start, calendar: calendar)
        }
    }
    private var selectedDayItems: [EventModel] { monthItemsByDay[selectedLocalDate] ?? [] }
    private var selectedOverride: WorkdayOverride? { controller.workdayOverrides[selectedLocalDate] }
    private var selectedSchedule: EffectiveWorkSchedule { controller.resolvedSchedule(on: selectedDate) }

    private var sourceDescription: String {
        if let selectedOverride {
            switch selectedOverride.kind {
            case .leaveDay: return String(localized: "Manual override · Leave day")
            case .temporaryWorkday: return String(localized: "Manual override · Temporary workday")
            case .customSchedule: return String(localized: "Manual override · Custom schedule")
            case .restDay: return String(localized: "Manual override · Rest day")
            case .publicHoliday: return String(localized: "Manual override · Public holiday")
            }
        }
        if let holiday = controller.holidayRule(on: selectedDate) {
            return holiday.kind == .publicHoliday
                ? String(localized: "Official calendar · \(holiday.name) holiday")
                : String(localized: "Official calendar · \(holiday.name)")
        }
        return selectedSchedule.isWorkday
            ? String(localized: "Recurring workday")
            : String(localized: "Recurring rest day")
    }

    private var statusColor: Color { statusColor(selectedSchedule) }

    private func statusLabel(_ schedule: EffectiveWorkSchedule) -> String {
        switch schedule.status {
        case .workday:
            return schedule.source == .makeupWorkday ? String(localized: "Makeup") : String(localized: "Work")
        case .restDay: return String(localized: "Rest")
        case .publicHoliday: return String(localized: "Holiday")
        case .leaveDay: return String(localized: "Leave")
        }
    }

    private func statusColor(_ schedule: EffectiveWorkSchedule) -> Color {
        switch schedule.status {
        case .workday: .green
        case .restDay: .secondary
        case .publicHoliday: .orange
        case .leaveDay: .pink
        }
    }

    private func selectToday() {
        selectedDate = Date()
        displayedMonth = calendar.startOfMonth(containing: selectedDate)
        loadSelection()
        resetCreationTimes(for: selectedDate)
    }

    private func loadCalendarContent() async {
        await calendarManager.prepareWorkCalendarAccess()
        await refreshMonthItems(for: displayedMonth)
    }

    private func moveMonth(_ offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        displayedMonth = calendar.startOfMonth(containing: next)
        selectedDate = displayedMonth
    }

    private func loadSelection() {
        customSchedule = selectedOverride?.schedule ?? LiveEarningsSchedule(config: controller.config)
        message = nil
    }

    private func resetCreationTimes(for date: Date) {
        itemStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        itemEnd = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date.addingTimeInterval(3600)
    }

    private func beginCreation(_ kind: CalendarCreationKind) {
        editingItem = nil
        creationKind = kind
        itemTitle = ""
        resetCreationTimes(for: selectedDate)
        showsCreationEditor = true
        message = nil
    }

    private func beginEditing(_ item: EventModel) {
        showsDayItemsOverlay = false
        editingItem = item
        creationKind = item.type.isReminder ? .todo : .event
        itemTitle = item.title
        itemStart = item.start
        itemEnd = item.end
        itemIsAllDay = item.isAllDay
        showsCreationEditor = true
        message = nil
    }

    private func dismissCreationEditor() {
        showsCreationEditor = false
        editingItem = nil
        itemTitle = ""
    }

    private func updateAutoCloseSuppression(_ active: Bool) {
        viewModel.setAutoCloseSuppression(active, token: autoCloseSuppressionToken)
        if active {
            AppDelegate.shared?.cancelPendingNotchAutoClose()
        } else {
            viewModel.shouldRecheckHover.toggle()
        }
    }

    private var editorTitle: String {
        if editingItem != nil {
            return creationKind == .todo
                ? String(localized: "Edit To-Do")
                : String(localized: "Edit Event")
        }
        return creationKind == .todo
            ? String(localized: "Add To-Do")
            : String(localized: "Add Event")
    }

    private func saveOverride(_ kind: WorkdayOverrideKind) async {
        do {
            let schedule = kind == .customSchedule ? customSchedule : nil
            try await controller.setOverride(on: selectedDate, kind: kind, schedule: schedule)
            message = String(localized: "Saved")
        } catch {
            message = error.localizedDescription
        }
    }

    private func restoreAutomatic() async {
        do {
            try await controller.removeOverride(on: selectedDate)
            loadSelection()
            message = String(localized: "Saved")
        } catch {
            message = error.localizedDescription
        }
    }

    private func createItem() async {
        let title = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let editingItem {
                if editingItem.type.isReminder {
                    try await calendarManager.updateReminder(id: editingItem.id, title: title, due: itemStart)
                } else {
                    try await calendarManager.updateEvent(
                        id: editingItem.id,
                        title: title,
                        start: itemStart,
                        end: itemEnd,
                        isAllDay: itemIsAllDay
                    )
                }
            } else {
                switch creationKind {
                case .event:
                    try await calendarManager.createEvent(title: title, start: itemStart, end: itemEnd, isAllDay: itemIsAllDay)
                case .todo:
                    try await calendarManager.createReminder(title: title, due: itemStart)
                }
            }
            await refreshMonthItems(for: displayedMonth)
            dismissCreationEditor()
            message = String(localized: "Saved")
        } catch {
            message = error.localizedDescription
        }
    }

    private func toggleReminderCompletion(_ item: EventModel) async {
        await calendarManager.setReminderCompleted(
            reminderID: item.id,
            completed: !reminderCompleted(item)
        )
        await refreshMonthItems(for: displayedMonth)
    }

    private func deleteItem(_ item: EventModel) async {
        itemPendingDeletion = nil
        do {
            try await calendarManager.deleteCalendarItem(id: item.id, isReminder: item.type.isReminder)
            await refreshMonthItems(for: displayedMonth)
            if selectedDayItems.isEmpty {
                showsDayItemsOverlay = false
            }
            message = String(localized: "Saved")
        } catch {
            message = error.localizedDescription
        }
    }

    private func deleteAllAtollItems() async {
        guard !isDeletingAllAtollItems else { return }
        isDeletingAllAtollItems = true
        let result = await calendarManager.deleteAllAtollManagedCalendarItems()
        await refreshMonthItems(for: displayedMonth)
        isDeletingAllAtollItems = false
        showsBulkDeletionConfirmation = false

        if result.failed == 0 {
            message = String.localizedStringWithFormat(
                String(localized: "Deleted %lld Atoll items."),
                result.deleted
            )
        } else {
            message = String.localizedStringWithFormat(
                String(localized: "Deleted %lld Atoll items; %lld could not be deleted."),
                result.deleted,
                result.failed
            )
        }
    }

    private func reminderCompleted(_ item: EventModel) -> Bool {
        guard case let .reminder(completed) = item.type else { return false }
        return completed
    }

    private func refreshMonthItems(for month: Date) async {
        let requestedMonth = calendar.startOfMonth(containing: month)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: requestedMonth) else { return }
        _ = await calendarManager.calendarItems(from: requestedMonth, to: nextMonth)
    }

    private func eventColor(_ event: EventModel) -> Color {
        Color(nsColor: event.calendar.color)
    }

    private func eventTime(_ event: EventModel) -> String {
        if event.isAllDay { return String(localized: "All-day") }
        return event.start.formatted(date: .omitted, time: .shortened)
    }

    private func timeBinding(_ keyPath: WritableKeyPath<LiveEarningsSchedule, LiveEarningsLocalTime>) -> Binding<Date> {
        Binding {
            let value = customSchedule[keyPath: keyPath]
            return calendar.date(bySettingHour: value.hour, minute: value.minute, second: 0, of: selectedDate) ?? selectedDate
        } set: { value in
            let components = calendar.dateComponents([.hour, .minute], from: value)
            customSchedule[keyPath: keyPath] = .init(hour: components.hour ?? 0, minute: components.minute ?? 0)
        }
    }
}
