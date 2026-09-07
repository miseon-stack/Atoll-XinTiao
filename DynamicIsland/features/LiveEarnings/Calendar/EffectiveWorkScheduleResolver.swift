/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation

protocol EffectiveWorkScheduleResolving: Sendable {
    func resolve(
        date: Date,
        config: LiveEarningsConfig,
        holidayRule: HolidayDateRule?,
        userOverride: WorkdayOverride?,
        calendarVersion: String?,
        calendar: Calendar
    ) -> EffectiveWorkSchedule
}

struct EffectiveWorkScheduleResolver: EffectiveWorkScheduleResolving, Sendable {
    func resolve(
        date: Date,
        config: LiveEarningsConfig,
        holidayRule: HolidayDateRule?,
        userOverride: WorkdayOverride?,
        calendarVersion: String?,
        calendar: Calendar
    ) -> EffectiveWorkSchedule {
        let localDate = LocalDate(date, calendar: calendar)
        let globalSchedule = LiveEarningsSchedule(config: config)

        if let userOverride {
            switch userOverride.kind {
            case .leaveDay:
                return .init(
                    date: localDate,
                    isWorkday: false,
                    status: .leaveDay,
                    schedule: nil,
                    source: .userOverride,
                    calendarVersion: calendarVersion,
                    countsTowardMonthlyDenominator: plannedWorkdayWithoutLeave(
                        date: date,
                        config: config,
                        holidayRule: holidayRule,
                        calendar: calendar
                    )
                )
            case .restDay:
                return .init(
                    date: localDate,
                    isWorkday: false,
                    status: .restDay,
                    schedule: nil,
                    source: .userOverride,
                    calendarVersion: calendarVersion,
                    countsTowardMonthlyDenominator: false
                )
            case .publicHoliday:
                return .init(
                    date: localDate,
                    isWorkday: false,
                    status: .publicHoliday,
                    schedule: nil,
                    source: .userOverride,
                    calendarVersion: calendarVersion,
                    countsTowardMonthlyDenominator: false
                )
            case .temporaryWorkday, .customSchedule:
                return .init(
                    date: localDate,
                    isWorkday: true,
                    status: .workday,
                    schedule: userOverride.schedule ?? globalSchedule,
                    source: .userOverride,
                    calendarVersion: calendarVersion,
                    countsTowardMonthlyDenominator: true
                )
            }
        }

        if let holidayRule {
            switch holidayRule.kind {
            case .publicHoliday:
                return .init(
                    date: localDate,
                    isWorkday: false,
                    status: .publicHoliday,
                    schedule: nil,
                    source: .publicHoliday,
                    calendarVersion: calendarVersion,
                    countsTowardMonthlyDenominator: false
                )
            case .makeupWorkday:
                return .init(
                    date: localDate,
                    isWorkday: true,
                    status: .workday,
                    schedule: globalSchedule,
                    source: .makeupWorkday,
                    calendarVersion: calendarVersion,
                    countsTowardMonthlyDenominator: true
                )
            }
        }

        let weekday = LiveEarningsWeekday(rawValue: calendar.component(.weekday, from: date))
        let recurring = weekday.map(config.workdays.contains) ?? false
        return .init(
            date: localDate,
            isWorkday: recurring,
            status: recurring ? .workday : .restDay,
            schedule: recurring ? globalSchedule : nil,
            source: recurring ? .recurringWeekday : .defaultRestDay,
            calendarVersion: calendarVersion,
            countsTowardMonthlyDenominator: recurring
        )
    }

    private func plannedWorkdayWithoutLeave(
        date: Date,
        config: LiveEarningsConfig,
        holidayRule: HolidayDateRule?,
        calendar: Calendar
    ) -> Bool {
        if let holidayRule { return holidayRule.kind == .makeupWorkday }
        guard let weekday = LiveEarningsWeekday(rawValue: calendar.component(.weekday, from: date)) else { return false }
        return config.workdays.contains(weekday)
    }
}
