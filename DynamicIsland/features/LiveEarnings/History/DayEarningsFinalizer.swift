/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation

actor DayEarningsFinalizer {
    static let shared = DayEarningsFinalizer()

    private let store: DayEarningsStore
    private let pendingURL: URL
    private var lastPendingSignature: String?

    init(
        store: DayEarningsStore = .shared,
        pendingURL: URL = LiveEarningsFileLocations.pendingDayURL
    ) {
        self.store = store
        self.pendingURL = pendingURL
    }

    func observe(
        date: Date,
        config: LiveEarningsConfig,
        effectiveSchedule: EffectiveWorkSchedule,
        monthlyWorkdayCount: Int,
        snapshot: LiveEarningsSnapshot,
        calendar: Calendar
    ) async throws {
        guard config.isEnabled, config.setupCompleted else { return }
        let localDate = LocalDate(date, calendar: calendar)
        try await recoverIfNeeded(now: date, calendar: calendar)

        let context = PendingDayContext(
            date: localDate,
            config: config,
            effectiveSchedule: EffectiveWorkScheduleCodable(effectiveSchedule),
            monthlyWorkdayCount: monthlyWorkdayCount,
            savedAt: date
        )
        let signature = try signature(for: context)
        if signature != lastPendingSignature {
            try writePending(context)
            lastPendingSignature = signature
        }

        if snapshot.status == .afterWork {
            try await finalize(
                date: localDate,
                config: config,
                effectiveSchedule: effectiveSchedule,
                snapshot: snapshot
            )
        }
    }

    func recoverIfNeeded(now: Date, calendar: Calendar) async throws {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
        let data = try Data(contentsOf: pendingURL)
        let context = try JSONDecoder.atollWorkCalendar.decode(PendingDayContext.self, from: data)
        guard await (try store.record(on: context.date)) == nil,
              let baseDate = context.date.date(in: calendar) else {
            try? FileManager.default.removeItem(at: pendingURL)
            return
        }
        let today = LocalDate(now, calendar: calendar)
        let endDate: Date? = context.effectiveSchedule.schedule.flatMap { schedule in
            calendar.date(
                bySettingHour: schedule.workEnd.hour,
                minute: schedule.workEnd.minute,
                second: 0,
                of: baseDate
            )
        }
        guard context.date < today || endDate.map({ now >= $0 }) == true else { return }

        let snapshot: LiveEarningsSnapshot
        if let endDate {
            let engine = LiveEarningsEngine(calendar: calendar)
            snapshot = engine.snapshot(
                at: endDate,
                config: context.config,
                effectiveSchedule: context.effectiveSchedule.runtimeValue,
                monthlyWorkdayCount: context.monthlyWorkdayCount
            )
        } else {
            let status: LiveEarningsStatus
            switch context.effectiveSchedule.status {
            case .publicHoliday: status = .publicHoliday
            case .leaveDay: status = .leaveDay
            case .restDay: status = .restDay
            case .workday: status = .invalidConfiguration
            }
            snapshot = .empty(at: baseDate, status: status)
        }
        try await finalize(
            date: context.date,
            config: context.config,
            effectiveSchedule: context.effectiveSchedule.runtimeValue,
            snapshot: snapshot
        )
    }

    private func finalize(
        date: LocalDate,
        config: LiveEarningsConfig,
        effectiveSchedule: EffectiveWorkSchedule,
        snapshot: LiveEarningsSnapshot
    ) async throws {
        guard try await store.record(on: date) == nil else {
            try? FileManager.default.removeItem(at: pendingURL)
            return
        }
        let record = DayEarningsRecord(
            date: date,
            status: status(for: effectiveSchedule.status),
            finalAmount: snapshot.earnedAmount,
            currencyCode: config.currencyCode,
            paidSeconds: snapshot.totalPaidSeconds,
            salaryMode: config.salaryMode,
            scheduleSource: effectiveSchedule.source,
            ruleVersion: effectiveSchedule.calendarVersion,
            revision: 1,
            finalizedAt: Date()
        )
        try await store.upsert(record)
        try? FileManager.default.removeItem(at: pendingURL)
        lastPendingSignature = nil
    }

    private func status(for status: EffectiveDayStatus) -> DayEarningsStatus {
        switch status {
        case .workday: .completedWorkday
        case .publicHoliday: .publicHoliday
        case .restDay: .restDay
        case .leaveDay: .leaveDay
        }
    }

    private func signature(for context: PendingDayContext) throws -> String {
        var value = context
        value.savedAt = .distantPast
        return try JSONEncoder.atollWorkCalendar.encode(value).base64EncodedString()
    }

    private func writePending(_ context: PendingDayContext) throws {
        try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.atollWorkCalendar.encode(context)
        try data.write(to: pendingURL, options: .atomic)
    }
}
