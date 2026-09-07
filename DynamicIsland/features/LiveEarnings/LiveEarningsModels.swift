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

enum LiveEarningsSalaryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case monthly
    case daily
    case hourly

    var id: String { rawValue }
}

enum LiveEarningsWeekday: Int, Codable, CaseIterable, Identifiable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: Int { rawValue }

    static let standardWorkweek: Set<Self> = [.monday, .tuesday, .wednesday, .thursday, .friday]
}

struct LiveEarningsLocalTime: Codable, Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    var minutesSinceMidnight: Int { hour * 60 + minute }
}

struct LiveEarningsConfig: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var isEnabled = false
    var setupCompleted = false
    var salaryMode: LiveEarningsSalaryMode = .monthly
    var monthlySalary = 0.0
    var dailySalary = 0.0
    var hourlyRate = 0.0
    var currencyCode = LiveEarningsConfig.recommendedCurrencyCode
    var workdays = LiveEarningsWeekday.standardWorkweek
    var workStart = LiveEarningsLocalTime(hour: 9, minute: 0)
    var workEnd = LiveEarningsLocalTime(hour: 18, minute: 0)
    var lunchBreakEnabled = false
    var lunchStart = LiveEarningsLocalTime(hour: 12, minute: 0)
    var lunchEnd = LiveEarningsLocalTime(hour: 13, minute: 0)
    var privacyModeEnabled = false
    /// Optional for backward-compatible decoding of phase-one configurations.
    /// A missing value resolves to the default green in the presentation layer.
    var closedAmountColorHex: String?

    static var recommendedCurrencyCode: String {
        Locale.current.currency?.identifier ?? "CNY"
    }

    var selectedSalary: Double {
        switch salaryMode {
        case .monthly: monthlySalary
        case .daily: dailySalary
        case .hourly: hourlyRate
        }
    }
}

enum LiveEarningsStatus: String, Codable, Sendable {
    case notConfigured
    case invalidConfiguration
    case restDay
    case publicHoliday
    case leaveDay
    case beforeWork
    case working
    case lunchBreak
    case afterWork
}

struct LiveEarningsSnapshot: Equatable, Sendable {
    var status: LiveEarningsStatus
    var earnedAmount: Decimal
    var estimatedDailyAmount: Decimal
    var progress: Double
    var elapsedPaidSeconds: TimeInterval
    var totalPaidSeconds: TimeInterval
    var nextTransition: Date?
    var generatedAt: Date

    static func empty(at date: Date = Date(), status: LiveEarningsStatus = .notConfigured) -> Self {
        .init(
            status: status,
            earnedAmount: 0,
            estimatedDailyAmount: 0,
            progress: 0,
            elapsedPaidSeconds: 0,
            totalPaidSeconds: 0,
            nextTransition: nil,
            generatedAt: date
        )
    }
}

enum LiveEarningsValidationIssue: String, Error, CaseIterable, Sendable {
    case salaryMustBePositive
    case selectAtLeastOneWorkday
    case workTimeOutOfRange
    case workEndMustBeAfterStart
    case lunchTimeOutOfRange
    case lunchMustBeInsideWorkday
}
