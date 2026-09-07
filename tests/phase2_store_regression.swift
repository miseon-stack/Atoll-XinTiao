import Foundation

@main
enum Phase2StoreRegression {
    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "Phase2StoreRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-phase2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let localDate = LocalDate(year: 2026, month: 8, day: 25)
        let encodedDate = try JSONEncoder().encode(localDate)
        try expect(String(data: encodedDate, encoding: .utf8) == "\"2026-08-25\"", "LocalDate uses stable date keys")
        let decodedDate = try JSONDecoder().decode(LocalDate.self, from: encodedDate)
        try expect(decodedDate == localDate, "LocalDate round trip")

        let overrideStore = WorkdayOverrideStore(fileURL: temporary.appendingPathComponent("overrides.json"))
        let now = Date()
        let leave = WorkdayOverride(date: localDate, kind: .leaveDay, schedule: nil, createdAt: now, updatedAt: now)
        try await overrideStore.upsert(leave)
        let storedLeave = try await overrideStore.override(on: localDate)
        try expect(storedLeave?.kind == .leaveDay, "override is persisted")

        var config = LiveEarningsConfig()
        config.isEnabled = true
        config.setupCompleted = true
        config.salaryMode = .daily
        config.dailySalary = 800
        let temporaryWork = WorkdayOverride(
            date: localDate,
            kind: .temporaryWorkday,
            schedule: LiveEarningsSchedule(config: config),
            createdAt: now.addingTimeInterval(10),
            updatedAt: now.addingTimeInterval(10)
        )
        try await overrideStore.upsert(temporaryWork)
        let replaced = try await overrideStore.override(on: localDate)
        try expect(replaced?.kind == .temporaryWorkday, "upsert replaces the same date")
        try expect(replaced?.createdAt == now, "upsert preserves original creation time")
        try await overrideStore.remove(on: localDate)
        let remainingOverrides = try await overrideStore.all()
        try expect(remainingOverrides.isEmpty, "override removal restores automatic rules")

        let historyStore = DayEarningsStore(fileURL: temporary.appendingPathComponent("history.json"))
        let record = DayEarningsRecord(
            date: localDate,
            status: .completedWorkday,
            finalAmount: 800,
            currencyCode: "CNY",
            paidSeconds: 28_800,
            salaryMode: .daily,
            scheduleSource: .recurringWeekday,
            ruleVersion: "cn-2026-1",
            revision: 1,
            finalizedAt: now
        )
        try await historyStore.upsert(record)
        let storedRecord = try await historyStore.record(on: localDate)
        try expect(storedRecord?.finalAmount == 800, "daily record is persisted")
        var sameRevision = record
        sameRevision.finalAmount = 1
        try await historyStore.upsert(sameRevision)
        let unchangedRecord = try await historyStore.record(on: localDate)
        try expect(unchangedRecord?.finalAmount == 800, "finalized record is immutable by default")
        var correction = record
        correction.revision = 2
        correction.finalAmount = 801
        try await historyStore.upsert(correction)
        let correctedRecord = try await historyStore.record(on: localDate)
        try expect(correctedRecord?.finalAmount == 801, "explicit higher revision can correct a record")
        try await historyStore.removeAll()
        let remainingHistory = try await historyStore.all()
        try expect(remainingHistory.isEmpty, "history clear is scoped to history")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 19))!
        let effective = EffectiveWorkSchedule(
            date: localDate,
            isWorkday: true,
            status: .workday,
            schedule: LiveEarningsSchedule(config: config),
            source: .recurringWeekday,
            calendarVersion: "cn-2026-1",
            countsTowardMonthlyDenominator: true
        )
        let snapshot = LiveEarningsEngine(calendar: calendar).snapshot(
            at: date,
            config: config,
            effectiveSchedule: effective,
            monthlyWorkdayCount: 21
        )
        let finalizer = DayEarningsFinalizer(
            store: historyStore,
            pendingURL: temporary.appendingPathComponent("pending.json")
        )
        try await finalizer.observe(
            date: date,
            config: config,
            effectiveSchedule: effective,
            monthlyWorkdayCount: 21,
            snapshot: snapshot,
            calendar: calendar
        )
        let finalizedRecord = try await historyStore.record(on: localDate)
        try expect(finalizedRecord?.finalAmount == 800, "after-work snapshot finalizes idempotently")

        print("Phase 2 stores: \(checks) checks passed")
    }
}
