/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation

struct LiveEarningsEngine: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func validate(_ config: LiveEarningsConfig) -> [LiveEarningsValidationIssue] {
        var issues: [LiveEarningsValidationIssue] = []
        if !config.selectedSalary.isFinite || config.selectedSalary <= 0 {
            issues.append(.salaryMustBePositive)
        }
        if config.workdays.isEmpty {
            issues.append(.selectAtLeastOneWorkday)
        }
        if !isValid(config.workStart) || !isValid(config.workEnd) {
            issues.append(.workTimeOutOfRange)
        } else if config.workEnd <= config.workStart {
            issues.append(.workEndMustBeAfterStart)
        }
        if config.lunchBreakEnabled {
            if !isValid(config.lunchStart) || !isValid(config.lunchEnd) {
                issues.append(.lunchTimeOutOfRange)
            } else if !(config.workStart < config.lunchStart
                        && config.lunchStart < config.lunchEnd
                        && config.lunchEnd < config.workEnd) {
                issues.append(.lunchMustBeInsideWorkday)
            }
        }
        return issues
    }

    func snapshot(at date: Date, config: LiveEarningsConfig) -> LiveEarningsSnapshot {
        guard config.setupCompleted, config.isEnabled else {
            return .empty(at: date, status: .notConfigured)
        }
        guard validate(config).isEmpty else {
            return .empty(at: date, status: .invalidConfiguration)
        }
        let resolver = EffectiveWorkScheduleResolver()
        let effectiveSchedule = resolver.resolve(
            date: date,
            config: config,
            holidayRule: nil,
            userOverride: nil,
            calendarVersion: nil,
            calendar: calendar
        )
        return snapshot(
            at: date,
            config: config,
            effectiveSchedule: effectiveSchedule,
            monthlyWorkdayCount: workdayCount(inMonthContaining: date, config: config)
        )
    }

    func snapshot(
        at date: Date,
        config: LiveEarningsConfig,
        effectiveSchedule: EffectiveWorkSchedule,
        monthlyWorkdayCount: Int
    ) -> LiveEarningsSnapshot {
        guard config.setupCompleted, config.isEnabled else {
            return .empty(at: date, status: .notConfigured)
        }
        guard validate(config).isEmpty else {
            return .empty(at: date, status: .invalidConfiguration)
        }
        guard effectiveSchedule.isWorkday, let schedule = effectiveSchedule.schedule else {
            let status: LiveEarningsStatus
            switch effectiveSchedule.status {
            case .publicHoliday: status = .publicHoliday
            case .leaveDay: status = .leaveDay
            case .restDay, .workday: status = .restDay
            }
            return .empty(at: date, status: status)
        }
        guard schedule.isValid,
              let workStart = self.date(onSameDayAs: date, at: schedule.workStart),
              let workEnd = self.date(onSameDayAs: date, at: schedule.workEnd) else {
            return .empty(at: date, status: .invalidConfiguration)
        }

        let lunch: DateInterval? = {
            guard schedule.lunchBreakEnabled,
                  let start = self.date(onSameDayAs: date, at: schedule.lunchStart),
                  let end = self.date(onSameDayAs: date, at: schedule.lunchEnd) else { return nil }
            return DateInterval(start: start, end: end)
        }()
        let totalPaid = max(0, workEnd.timeIntervalSince(workStart) - (lunch?.duration ?? 0))
        let estimated = estimatedDailyAmount(
            totalPaidSeconds: totalPaid,
            config: config,
            monthlyWorkdayCount: monthlyWorkdayCount
        )

        let status: LiveEarningsStatus
        let elapsed: TimeInterval
        let nextTransition: Date?
        if date < workStart {
            status = .beforeWork
            elapsed = 0
            nextTransition = workStart
        } else if let lunch, date >= lunch.start, date < lunch.end {
            status = .lunchBreak
            elapsed = lunch.start.timeIntervalSince(workStart)
            nextTransition = lunch.end
        } else if date < workEnd {
            status = .working
            let rawElapsed = date.timeIntervalSince(workStart)
            let deductedLunch: TimeInterval
            if let lunch, date >= lunch.end {
                deductedLunch = lunch.duration
            } else {
                deductedLunch = 0
            }
            elapsed = max(0, rawElapsed - deductedLunch)
            nextTransition = lunch.map { date < $0.start ? $0.start : workEnd } ?? workEnd
        } else {
            status = .afterWork
            elapsed = totalPaid
            nextTransition = nil
        }

        let progress = totalPaid > 0 ? min(max(elapsed / totalPaid, 0), 1) : 0
        return .init(
            status: status,
            earnedAmount: multiply(estimated, by: progress),
            estimatedDailyAmount: estimated,
            progress: progress,
            elapsedPaidSeconds: elapsed,
            totalPaidSeconds: totalPaid,
            nextTransition: nextTransition,
            generatedAt: date
        )
    }

    func workdayCount(inMonthContaining date: Date, config: LiveEarningsConfig) -> Int {
        guard let range = calendar.range(of: .day, in: .month, for: date),
              let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else {
            return 0
        }
        return range.reduce(into: 0) { count, day in
            guard let candidate = calendar.date(byAdding: .day, value: day - 1, to: monthStart),
                  let weekday = LiveEarningsWeekday(rawValue: calendar.component(.weekday, from: candidate)) else { return }
            if config.workdays.contains(weekday) { count += 1 }
        }
    }

    func workdayCount(
        inMonthContaining date: Date,
        config: LiveEarningsConfig,
        holidayCalendar: HolidayCalendarProviding,
        overrides: [LocalDate: WorkdayOverride]
    ) -> Int {
        guard let range = calendar.range(of: .day, in: .month, for: date),
              let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else {
            return 0
        }
        let resolver = EffectiveWorkScheduleResolver()
        return range.reduce(into: 0) { count, day in
            guard let candidate = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return }
            let localDate = LocalDate(candidate, calendar: calendar)
            let schedule = resolver.resolve(
                date: candidate,
                config: config,
                holidayRule: holidayCalendar.rule(on: localDate),
                userOverride: overrides[localDate],
                calendarVersion: holidayCalendar.version,
                calendar: calendar
            )
            if schedule.countsTowardMonthlyDenominator { count += 1 }
        }
    }

    private func estimatedDailyAmount(
        totalPaidSeconds: TimeInterval,
        config: LiveEarningsConfig,
        monthlyWorkdayCount: Int
    ) -> Decimal {
        switch config.salaryMode {
        case .monthly:
            guard monthlyWorkdayCount > 0 else { return 0 }
            return divide(decimal(config.monthlySalary), by: Decimal(monthlyWorkdayCount))
        case .daily:
            return decimal(config.dailySalary)
        case .hourly:
            return multiply(decimal(config.hourlyRate), by: totalPaidSeconds / 3600)
        }
    }

    private func date(onSameDayAs date: Date, at time: LiveEarningsLocalTime) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date)
    }

    private func isValid(_ time: LiveEarningsLocalTime) -> Bool {
        (0...23).contains(time.hour) && (0...59).contains(time.minute)
    }

    private func decimal(_ value: Double) -> Decimal {
        NSDecimalNumber(value: value).decimalValue
    }

    private func multiply(_ amount: Decimal, by multiplier: Double) -> Decimal {
        NSDecimalNumber(decimal: amount)
            .multiplying(by: NSDecimalNumber(value: multiplier))
            .decimalValue
    }

    private func divide(_ amount: Decimal, by divisor: Decimal) -> Decimal {
        NSDecimalNumber(decimal: amount)
            .dividing(by: NSDecimalNumber(decimal: divisor))
            .decimalValue
    }
}
