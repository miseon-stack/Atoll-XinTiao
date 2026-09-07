/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import Combine
import Defaults
import Foundation

@MainActor
final class LiveEarningsController: ObservableObject {
    static let shared = LiveEarningsController()

    @Published private(set) var config: LiveEarningsConfig
    @Published private(set) var snapshot: LiveEarningsSnapshot
    @Published private(set) var validationIssues: [LiveEarningsValidationIssue]
    @Published private(set) var effectiveSchedule: EffectiveWorkSchedule
    @Published private(set) var workdayOverrides: [LocalDate: WorkdayOverride] = [:]
    @Published private(set) var workCalendarError: String?
    @Published private(set) var historyRecords: [DayEarningsRecord] = []
    @Published private(set) var historyError: String?

    private let engine: LiveEarningsEngine
    private let holidayCalendar: HolidayCalendarStore
    private let scheduleResolver = EffectiveWorkScheduleResolver()
    private let overrideStore: WorkdayOverrideStore
    private let historyStore: DayEarningsStore
    private let dayFinalizer: DayEarningsFinalizer
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    private init(
        engine: LiveEarningsEngine = LiveEarningsEngine(),
        holidayCalendar: HolidayCalendarStore = HolidayCalendarStore(),
        overrideStore: WorkdayOverrideStore = .shared,
        historyStore: DayEarningsStore = .shared,
        dayFinalizer: DayEarningsFinalizer = .shared
    ) {
        self.engine = engine
        self.holidayCalendar = holidayCalendar
        self.overrideStore = overrideStore
        self.historyStore = historyStore
        self.dayFinalizer = dayFinalizer
        let stored = Defaults[.liveEarningsConfig]
        let now = Date()
        let localDate = LocalDate(now, calendar: engine.calendar)
        let resolver = EffectiveWorkScheduleResolver()
        let initialSchedule = resolver.resolve(
            date: now,
            config: stored,
            holidayRule: holidayCalendar.rule(on: localDate),
            userOverride: nil,
            calendarVersion: holidayCalendar.version,
            calendar: engine.calendar
        )
        config = stored
        validationIssues = engine.validate(stored)
        effectiveSchedule = initialSchedule
        snapshot = engine.snapshot(
            at: now,
            config: stored,
            effectiveSchedule: initialSchedule,
            monthlyWorkdayCount: engine.workdayCount(
                inMonthContaining: now,
                config: stored,
                holidayCalendar: holidayCalendar,
                overrides: [:]
            )
        )
        workCalendarError = nil
        historyError = nil
        observeChanges()
        reschedule()
        Task { [weak self] in
            guard let self else { return }
            await self.reloadWorkdayOverrides()
            do {
                try await self.dayFinalizer.recoverIfNeeded(now: Date(), calendar: engine.calendar)
            } catch {
                self.historyError = error.localizedDescription
            }
            await self.reloadHistory()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var shouldShowClosedAmount: Bool {
        guard !LockScreenManager.shared.isLocked,
              !config.privacyModeEnabled,
              config.isEnabled,
              config.setupCompleted,
              validationIssues.isEmpty else { return false }
        return ![.restDay, .publicHoliday, .leaveDay, .notConfigured].contains(snapshot.status)
    }

    var shouldShowHomeCard: Bool {
        guard !LockScreenManager.shared.isLocked,
              config.isEnabled,
              config.setupCompleted,
              validationIssues.isEmpty else { return false }
        return snapshot.status != .notConfigured
    }

    var formattedAmountWithoutSymbol: String {
        LiveEarningsFormatting.amount(
            snapshot.earnedAmount,
            currencyCode: config.currencyCode,
            includesSymbol: false,
            usesGroupingSeparator: false
        )
    }

    var formattedAmountWithCurrency: String {
        LiveEarningsFormatting.amount(snapshot.earnedAmount, currencyCode: config.currencyCode, includesSymbol: true)
    }

    var closedAmountIntegerDigitCount: Int {
        let rawAmount = NSDecimalNumber(decimal: snapshot.earnedAmount).stringValue
        let integerPart = rawAmount.split(separator: ".", maxSplits: 1).first ?? "0"
        return max(1, integerPart.filter(\.isNumber).count)
    }

    func save(_ newConfig: LiveEarningsConfig) {
        // Apply first so every visible surface recomputes immediately. The
        // Defaults publisher still keeps this controller in sync with changes
        // made by another settings window or a future extension.
        config = newConfig
        Defaults[.liveEarningsConfig] = newConfig
        refresh()
    }

    func skipSetup() {
        var skipped = LiveEarningsConfig()
        skipped.setupCompleted = true
        skipped.isEnabled = false
        save(skipped)
    }

    func refresh(at date: Date = Date()) {
        validationIssues = engine.validate(config)
        effectiveSchedule = resolvedSchedule(on: date)
        let monthlyWorkdayCount = engine.workdayCount(
            inMonthContaining: date,
            config: config,
            holidayCalendar: holidayCalendar,
            overrides: workdayOverrides
        )
        snapshot = engine.snapshot(
            at: date,
            config: config,
            effectiveSchedule: effectiveSchedule,
            monthlyWorkdayCount: monthlyWorkdayCount
        )
        let capturedConfig = config
        let capturedSchedule = effectiveSchedule
        let capturedSnapshot = snapshot
        let capturedCalendar = engine.calendar
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dayFinalizer.observe(
                    date: date,
                    config: capturedConfig,
                    effectiveSchedule: capturedSchedule,
                    monthlyWorkdayCount: monthlyWorkdayCount,
                    snapshot: capturedSnapshot,
                    calendar: capturedCalendar
                )
                if capturedSnapshot.status == .afterWork { await self.reloadHistory() }
            } catch {
                self.historyError = error.localizedDescription
            }
        }
        reschedule()
    }

    func resolvedSchedule(on date: Date) -> EffectiveWorkSchedule {
        let localDate = LocalDate(date, calendar: engine.calendar)
        return scheduleResolver.resolve(
            date: date,
            config: config,
            holidayRule: holidayCalendar.rule(on: localDate),
            userOverride: workdayOverrides[localDate],
            calendarVersion: holidayCalendar.version,
            calendar: engine.calendar
        )
    }

    func holidayRule(on date: Date) -> HolidayDateRule? {
        holidayCalendar.rule(on: LocalDate(date, calendar: engine.calendar))
    }

    func isHolidayYearCovered(_ year: Int) -> Bool {
        holidayCalendar.isYearCovered(year)
    }

    func setOverride(
        on date: Date,
        kind: WorkdayOverrideKind,
        schedule: LiveEarningsSchedule? = nil
    ) async throws {
        let localDate = LocalDate(date, calendar: engine.calendar)
        let now = Date()
        let existing = workdayOverrides[localDate]
        let item = WorkdayOverride(
            date: localDate,
            kind: kind,
            schedule: schedule,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try await overrideStore.upsert(item)
        await reloadWorkdayOverrides()
    }

    func removeOverride(on date: Date) async throws {
        try await overrideStore.remove(on: LocalDate(date, calendar: engine.calendar))
        await reloadWorkdayOverrides()
    }

    func removeAllOverrides() async throws {
        try await overrideStore.removeAll()
        await reloadWorkdayOverrides()
    }

    func reloadWorkdayOverrides() async {
        do {
            let items = try await overrideStore.all()
            workdayOverrides = Dictionary(uniqueKeysWithValues: items.map { ($0.date, $0) })
            workCalendarError = nil
            refresh()
        } catch {
            workCalendarError = error.localizedDescription
            refresh()
        }
    }

    func reloadHistory() async {
        do {
            historyRecords = try await historyStore.all()
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    func clearHistory() async throws {
        try await historyStore.removeAll()
        await reloadHistory()
    }

    private func observeChanges() {
        Defaults.publisher(.liveEarningsConfig, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self else { return }
                guard self.config != change.newValue else { return }
                self.config = change.newValue
                self.refresh()
            }
            .store(in: &cancellables)

        LockScreenManager.shared.$isLocked
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        let notifications: [(NotificationCenter, Notification.Name)] = [
            (.default, .NSCalendarDayChanged),
            (.default, .NSSystemClockDidChange),
            (.default, .NSSystemTimeZoneDidChange),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        ]
        for (center, name) in notifications {
            center.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }
    }

    private func reschedule() {
        refreshTask?.cancel()
        guard config.isEnabled, config.setupCompleted else { return }

        let now = Date()
        let delay: TimeInterval
        if snapshot.status == .working,
           !config.privacyModeEnabled,
           !LockScreenManager.shared.isLocked {
            delay = 1
        } else if let next = snapshot.nextTransition {
            delay = max(0.25, next.timeIntervalSince(now))
        } else {
            let calendar = Calendar.autoupdatingCurrent
            let startOfTomorrow = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: now)
            ) ?? now.addingTimeInterval(86_400)
            delay = max(0.25, startOfTomorrow.timeIntervalSince(now))
        }

        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}

enum LiveEarningsFormatting {
    static func amount(
        _ amount: Decimal,
        currencyCode: String,
        includesSymbol: Bool,
        usesGroupingSeparator: Bool = true
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = includesSymbol ? .currency : .decimal
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = usesGroupingSeparator
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "0.00"
    }
}
