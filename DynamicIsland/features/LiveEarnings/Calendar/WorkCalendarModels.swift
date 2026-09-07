/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Phase-two local work-calendar domain models.
 */

import Foundation

struct LocalDate: Hashable, Comparable, Sendable, Identifiable {
    let year: Int
    let month: Int
    let day: Int

    var id: String { encoded }
    var encoded: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension LocalDate: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let pieces = value.split(separator: "-")
        guard pieces.count == 3,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected a YYYY-MM-DD local date"
            )
        }
        self.init(year: year, month: month, day: day)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }
}

struct LiveEarningsSchedule: Codable, Equatable, Sendable {
    var workStart: LiveEarningsLocalTime
    var workEnd: LiveEarningsLocalTime
    var lunchBreakEnabled: Bool
    var lunchStart: LiveEarningsLocalTime
    var lunchEnd: LiveEarningsLocalTime

    init(config: LiveEarningsConfig) {
        workStart = config.workStart
        workEnd = config.workEnd
        lunchBreakEnabled = config.lunchBreakEnabled
        lunchStart = config.lunchStart
        lunchEnd = config.lunchEnd
    }

    var isValid: Bool {
        guard Self.isValid(workStart), Self.isValid(workEnd), workStart < workEnd else { return false }
        guard lunchBreakEnabled else { return true }
        return Self.isValid(lunchStart)
            && Self.isValid(lunchEnd)
            && workStart < lunchStart
            && lunchStart < lunchEnd
            && lunchEnd < workEnd
    }

    private static func isValid(_ value: LiveEarningsLocalTime) -> Bool {
        (0...23).contains(value.hour) && (0...59).contains(value.minute)
    }
}

enum HolidayDateKind: String, Codable, Sendable {
    case publicHoliday
    case makeupWorkday
}

struct HolidayDateRule: Codable, Equatable, Sendable {
    var date: LocalDate
    var kind: HolidayDateKind
    var name: String
}

struct HolidayCalendarDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var calendar: String
    var year: Int
    var version: String
    var publishedAt: LocalDate
    var sourceTitle: String
    var sourceURL: String
    var dates: [HolidayDateRule]

    func validated() throws -> Self {
        guard schemaVersion == 1 else { throw WorkCalendarError.unsupportedSchema }
        guard calendar == "CN", !version.isEmpty, !sourceTitle.isEmpty,
              URL(string: sourceURL)?.scheme?.hasPrefix("http") == true else {
            throw WorkCalendarError.invalidCalendarDocument
        }
        var seen = Set<LocalDate>()
        for rule in dates {
            guard rule.date.year == year, !rule.name.isEmpty, seen.insert(rule.date).inserted else {
                throw WorkCalendarError.invalidCalendarDocument
            }
        }
        return self
    }
}

enum WorkdayOverrideKind: String, Codable, CaseIterable, Sendable {
    case leaveDay
    case temporaryWorkday
    case customSchedule
    case restDay
    case publicHoliday
}

struct WorkdayOverride: Codable, Equatable, Sendable, Identifiable {
    var date: LocalDate
    var kind: WorkdayOverrideKind
    var schedule: LiveEarningsSchedule?
    var createdAt: Date
    var updatedAt: Date

    var id: LocalDate { date }

    func validated() throws -> Self {
        switch kind {
        case .leaveDay, .restDay, .publicHoliday:
            guard schedule == nil else { throw WorkCalendarError.invalidOverride }
        case .temporaryWorkday:
            guard schedule?.isValid ?? true else { throw WorkCalendarError.invalidOverride }
        case .customSchedule:
            guard schedule?.isValid == true else { throw WorkCalendarError.invalidOverride }
        }
        return self
    }
}

enum EffectiveDayStatus: String, Codable, Sendable {
    case workday
    case restDay
    case publicHoliday
    case leaveDay
}

enum WorkScheduleSource: String, Codable, Sendable {
    case userOverride
    case publicHoliday
    case makeupWorkday
    case recurringWeekday
    case defaultRestDay
}

struct EffectiveWorkSchedule: Equatable, Sendable {
    var date: LocalDate
    var isWorkday: Bool
    var status: EffectiveDayStatus
    var schedule: LiveEarningsSchedule?
    var source: WorkScheduleSource
    var calendarVersion: String?
    /// Leave remains a planned day for the monthly denominator even though it earns zero.
    var countsTowardMonthlyDenominator: Bool
}

enum WorkCalendarError: LocalizedError, Sendable {
    case unsupportedSchema
    case invalidCalendarDocument
    case invalidOverride
    case corruptedStore

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "The work-calendar data version is not supported."
        case .invalidCalendarDocument: "The bundled work-calendar data is invalid."
        case .invalidOverride: "The date override is invalid."
        case .corruptedStore: "The saved work-calendar data could not be read."
        }
    }
}
