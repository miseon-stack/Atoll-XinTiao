import Foundation

@main
enum LiveEarningsRegression {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let engine = LiveEarningsEngine(calendar: calendar)

        var config = LiveEarningsConfig()
        config.setupCompleted = true
        config.isEnabled = true
        config.salaryMode = .daily
        config.dailySalary = 800
        config.lunchBreakEnabled = true

        try expect(engine.validate(config).isEmpty, "valid baseline configuration")
        try expect(engine.snapshot(at: date(2026, 8, 24, 8, 30, calendar), config: config).status == .beforeWork, "before work")
        try expect(amount(engine.snapshot(at: date(2026, 8, 24, 8, 30, calendar), config: config)) == 0, "before work amount")

        let eleven = engine.snapshot(at: date(2026, 8, 24, 11, 0, calendar), config: config)
        try expect(eleven.status == .working, "working status")
        try expect(eleven.progress == 0.25, "paid progress before lunch")
        try expect(amount(eleven) == 200, "amount before lunch")

        let lunch = engine.snapshot(at: date(2026, 8, 24, 12, 30, calendar), config: config)
        try expect(lunch.status == .lunchBreak, "lunch status")
        try expect(amount(lunch) == 300, "lunch amount freezes")

        let afternoon = engine.snapshot(at: date(2026, 8, 24, 14, 0, calendar), config: config)
        try expect(afternoon.progress == 0.5, "lunch deduction")
        try expect(amount(afternoon) == 400, "post-lunch amount")

        let finished = engine.snapshot(at: date(2026, 8, 24, 19, 0, calendar), config: config)
        try expect(finished.status == .afterWork, "after work status")
        try expect(amount(finished) == 800, "after work final amount")

        let rest = engine.snapshot(at: date(2026, 8, 23, 12, 0, calendar), config: config)
        try expect(rest.status == .restDay, "rest day")

        config.salaryMode = .hourly
        config.hourlyRate = 20
        try expect(amount(engine.snapshot(at: date(2026, 8, 24, 19, 0, calendar), config: config)) == 160, "hourly amount")

        config.salaryMode = .monthly
        config.monthlySalary = 21_000
        try expect(engine.workdayCount(inMonthContaining: date(2026, 8, 24, 12, 0, calendar), config: config) == 21, "actual selected weekdays in month")
        try expect(amount(engine.snapshot(at: date(2026, 8, 24, 19, 0, calendar), config: config)) == 1000, "monthly daily estimate")

        config.salaryMode = .daily
        config.dailySalary = 800
        config.workEnd = .init(hour: 23, minute: 0)
        let beforeEndTimeChange = engine.snapshot(at: date(2026, 8, 24, 19, 0, calendar), config: config)
        config.workEnd = .init(hour: 18, minute: 0)
        let afterEndTimeChange = engine.snapshot(at: date(2026, 8, 24, 19, 0, calendar), config: config)
        try expect(afterEndTimeChange.progress == 1 && beforeEndTimeChange.progress < 1, "work end change recomputes progress")
        try expect(amount(afterEndTimeChange) == 800 && amount(beforeEndTimeChange) < 800, "work end change recomputes amount")

        let reference = date(2026, 8, 24, 14, 23, calendar)
        try expect(engine.snapshot(at: reference, config: config) == engine.snapshot(at: reference, config: config), "restart recomputation is deterministic")

        config.workEnd = config.workStart
        try expect(engine.validate(config).contains(.workEndMustBeAfterStart), "reject zero-length workday")
        config.workEnd = .init(hour: 18, minute: 0)
        config.workdays = []
        try expect(engine.validate(config).contains(.selectAtLeastOneWorkday), "reject empty workweek")

        let phaseOneJSON = """
        {"schemaVersion":1,"isEnabled":true,"setupCompleted":true,"salaryMode":"monthly","monthlySalary":21000,"dailySalary":0,"hourlyRate":0,"currencyCode":"CNY","workdays":[2,3,4,5,6],"workStart":{"hour":9,"minute":0},"workEnd":{"hour":18,"minute":0},"lunchBreakEnabled":false,"lunchStart":{"hour":12,"minute":0},"lunchEnd":{"hour":13,"minute":0},"privacyModeEnabled":false}
        """
        let migrated = try JSONDecoder().decode(LiveEarningsConfig.self, from: Data(phaseOneJSON.utf8))
        try expect(migrated.closedAmountColorHex == nil, "phase-one settings decode with default amount color")

        let holidayURL = URL(fileURLWithPath: "DynamicIsland/HolidayCalendars/cn-2026.json")
        let holidayDocument = try JSONDecoder.atollWorkCalendar
            .decode(HolidayCalendarDocument.self, from: Data(contentsOf: holidayURL))
            .validated()
        let holidayStore = HolidayCalendarStore(documents: [holidayDocument])
        let resolver = EffectiveWorkScheduleResolver()

        config.workdays = LiveEarningsWeekday.standardWorkweek
        config.salaryMode = .monthly
        config.monthlySalary = 21_000
        let newYearsDay = date(2026, 1, 1, 12, 0, calendar)
        let newYearsSchedule = resolve(newYearsDay, config, holidayStore, nil, resolver, calendar)
        try expect(newYearsSchedule.status == .publicHoliday && !newYearsSchedule.isWorkday, "official holiday overrides weekday")
        try expect(engine.snapshot(at: newYearsDay, config: config, effectiveSchedule: newYearsSchedule, monthlyWorkdayCount: 20).status == .publicHoliday, "holiday has explicit snapshot status")

        let makeupSunday = date(2026, 1, 4, 12, 0, calendar)
        let makeupSchedule = resolve(makeupSunday, config, holidayStore, nil, resolver, calendar)
        try expect(makeupSchedule.isWorkday && makeupSchedule.source == .makeupWorkday, "official makeup day overrides weekend")

        let leave = WorkdayOverride(
            date: LocalDate(newYearsDay, calendar: calendar),
            kind: .temporaryWorkday,
            schedule: nil,
            createdAt: newYearsDay,
            updatedAt: newYearsDay
        )
        let manualSchedule = resolve(newYearsDay, config, holidayStore, leave, resolver, calendar)
        try expect(manualSchedule.isWorkday && manualSchedule.source == .userOverride, "manual override wins over official holiday")

        let normalMonday = date(2026, 8, 24, 12, 0, calendar)
        let leaveOverride = WorkdayOverride(
            date: LocalDate(normalMonday, calendar: calendar),
            kind: .leaveDay,
            schedule: nil,
            createdAt: normalMonday,
            updatedAt: normalMonday
        )
        let leaveSchedule = resolve(normalMonday, config, holidayStore, leaveOverride, resolver, calendar)
        try expect(leaveSchedule.status == .leaveDay && leaveSchedule.countsTowardMonthlyDenominator, "leave earns zero but remains in denominator")

        let restOverride = WorkdayOverride(
            date: LocalDate(normalMonday, calendar: calendar),
            kind: .restDay,
            schedule: nil,
            createdAt: normalMonday,
            updatedAt: normalMonday
        )
        let restOverrideSchedule = resolve(normalMonday, config, holidayStore, restOverride, resolver, calendar)
        try expect(restOverrideSchedule.status == .restDay && !restOverrideSchedule.countsTowardMonthlyDenominator, "manual rest day replaces a recurring workday")

        let publicHolidayOverride = WorkdayOverride(
            date: LocalDate(normalMonday, calendar: calendar),
            kind: .publicHoliday,
            schedule: nil,
            createdAt: normalMonday,
            updatedAt: normalMonday
        )
        let publicHolidayOverrideSchedule = resolve(normalMonday, config, holidayStore, publicHolidayOverride, resolver, calendar)
        try expect(publicHolidayOverrideSchedule.status == .publicHoliday && !publicHolidayOverrideSchedule.isWorkday, "manual public holiday is supported")

        let temporarySaturday = date(2026, 8, 29, 12, 0, calendar)
        let temporaryOverride = WorkdayOverride(
            date: LocalDate(temporarySaturday, calendar: calendar),
            kind: .temporaryWorkday,
            schedule: nil,
            createdAt: temporarySaturday,
            updatedAt: temporarySaturday
        )
        let baselineCount = engine.workdayCount(inMonthContaining: normalMonday, config: config, holidayCalendar: holidayStore, overrides: [:])
        let countWithLeave = engine.workdayCount(inMonthContaining: normalMonday, config: config, holidayCalendar: holidayStore, overrides: [leaveOverride.date: leaveOverride])
        let countWithTemporary = engine.workdayCount(inMonthContaining: normalMonday, config: config, holidayCalendar: holidayStore, overrides: [temporaryOverride.date: temporaryOverride])
        try expect(countWithLeave == baselineCount, "leave does not reduce monthly denominator")
        try expect(countWithTemporary == baselineCount + 1, "temporary workday increases monthly denominator")

        var shortSchedule = LiveEarningsSchedule(config: config)
        shortSchedule.workEnd = .init(hour: 17, minute: 0)
        let customOverride = WorkdayOverride(
            date: LocalDate(normalMonday, calendar: calendar),
            kind: .customSchedule,
            schedule: shortSchedule,
            createdAt: normalMonday,
            updatedAt: normalMonday
        )
        let customSchedule = resolve(normalMonday, config, holidayStore, customOverride, resolver, calendar)
        let customSnapshot = engine.snapshot(at: date(2026, 8, 24, 17, 30, calendar), config: config, effectiveSchedule: customSchedule, monthlyWorkdayCount: baselineCount)
        try expect(customSnapshot.status == .afterWork && customSnapshot.progress == 1, "single-day schedule changes transition immediately")
        try expect(!holidayStore.isYearCovered(2027) && holidayStore.rule(on: LocalDate(year: 2027, month: 1, day: 1)) == nil, "uncovered year safely falls back")

        print("Live Earnings regression: 31 checks passed")
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func amount(_ snapshot: LiveEarningsSnapshot) -> Decimal {
        snapshot.earnedAmount
    }

    private static func resolve(
        _ date: Date,
        _ config: LiveEarningsConfig,
        _ holidays: HolidayCalendarStore,
        _ override: WorkdayOverride?,
        _ resolver: EffectiveWorkScheduleResolver,
        _ calendar: Calendar
    ) -> EffectiveWorkSchedule {
        let localDate = LocalDate(date, calendar: calendar)
        return resolver.resolve(
            date: date,
            config: config,
            holidayRule: holidays.rule(on: localDate),
            userOverride: override,
            calendarVersion: holidays.version,
            calendar: calendar
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "LiveEarningsRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
