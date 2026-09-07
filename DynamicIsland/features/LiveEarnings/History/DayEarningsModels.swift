/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation

enum DayEarningsStatus: String, Codable, Sendable {
    case completedWorkday
    case publicHoliday
    case restDay
    case leaveDay
}

struct DayEarningsRecord: Codable, Equatable, Identifiable, Sendable {
    var id: LocalDate { date }
    var date: LocalDate
    var status: DayEarningsStatus
    var finalAmount: Decimal
    var currencyCode: String
    var paidSeconds: TimeInterval
    var salaryMode: LiveEarningsSalaryMode
    var scheduleSource: WorkScheduleSource
    var ruleVersion: String?
    var revision: Int
    var finalizedAt: Date
}

struct PendingDayContext: Codable, Equatable, Sendable {
    var date: LocalDate
    var config: LiveEarningsConfig
    var effectiveSchedule: EffectiveWorkScheduleCodable
    var monthlyWorkdayCount: Int
    var savedAt: Date
}

/// Codable representation kept separate so runtime EffectiveWorkSchedule can stay minimal.
struct EffectiveWorkScheduleCodable: Codable, Equatable, Sendable {
    var date: LocalDate
    var isWorkday: Bool
    var status: EffectiveDayStatus
    var schedule: LiveEarningsSchedule?
    var source: WorkScheduleSource
    var calendarVersion: String?
    var countsTowardMonthlyDenominator: Bool

    init(_ value: EffectiveWorkSchedule) {
        date = value.date
        isWorkday = value.isWorkday
        status = value.status
        schedule = value.schedule
        source = value.source
        calendarVersion = value.calendarVersion
        countsTowardMonthlyDenominator = value.countsTowardMonthlyDenominator
    }

    var runtimeValue: EffectiveWorkSchedule {
        .init(
            date: date,
            isWorkday: isWorkday,
            status: status,
            schedule: schedule,
            source: source,
            calendarVersion: calendarVersion,
            countsTowardMonthlyDenominator: countsTowardMonthlyDenominator
        )
    }
}
