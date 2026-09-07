/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation

protocol WorkdayOverrideStoring: Sendable {
    func all() async throws -> [WorkdayOverride]
    func override(on date: LocalDate) async throws -> WorkdayOverride?
    func upsert(_ override: WorkdayOverride) async throws
    func remove(on date: LocalDate) async throws
    func removeAll() async throws
}

private struct WorkdayOverrideDocument: Codable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var items: [WorkdayOverride] = []
}

actor WorkdayOverrideStore: WorkdayOverrideStoring {
    static let shared = WorkdayOverrideStore()

    private let fileURL: URL
    private var document: WorkdayOverrideDocument?

    init(fileURL: URL = LiveEarningsFileLocations.overridesURL) {
        self.fileURL = fileURL
    }

    func all() throws -> [WorkdayOverride] {
        try load().items.sorted { $0.date < $1.date }
    }

    func override(on date: LocalDate) throws -> WorkdayOverride? {
        try load().items.first { $0.date == date }
    }

    func upsert(_ override: WorkdayOverride) throws {
        let valid = try override.validated()
        var updated = try load()
        if let index = updated.items.firstIndex(where: { $0.date == valid.date }) {
            var replacement = valid
            replacement.createdAt = updated.items[index].createdAt
            updated.items[index] = replacement
        } else {
            updated.items.append(valid)
        }
        try persist(&updated)
    }

    func remove(on date: LocalDate) throws {
        var updated = try load()
        let oldCount = updated.items.count
        updated.items.removeAll { $0.date == date }
        guard updated.items.count != oldCount else { return }
        try persist(&updated)
    }

    func removeAll() throws {
        var updated = WorkdayOverrideDocument()
        updated.revision = (try? load().revision + 1) ?? 1
        try write(updated)
        document = updated
    }

    func revision() throws -> Int { try load().revision }

    private func load() throws -> WorkdayOverrideDocument {
        if let document { return document }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = WorkdayOverrideDocument()
            document = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.atollWorkCalendar.decode(WorkdayOverrideDocument.self, from: data)
            guard decoded.schemaVersion == 1 else { throw WorkCalendarError.unsupportedSchema }
            for item in decoded.items { _ = try item.validated() }
            document = decoded
            return decoded
        } catch let error as WorkCalendarError {
            throw error
        } catch {
            throw WorkCalendarError.corruptedStore
        }
    }

    private func persist(_ updated: inout WorkdayOverrideDocument) throws {
        updated.revision += 1
        updated.items.sort { $0.date < $1.date }
        try write(updated)
        document = updated
    }

    private func write(_ document: WorkdayOverrideDocument) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.atollWorkCalendar.encode(document)
        try data.write(to: fileURL, options: .atomic)
        _ = try JSONDecoder.atollWorkCalendar.decode(WorkdayOverrideDocument.self, from: Data(contentsOf: fileURL))
    }
}

enum LiveEarningsFileLocations {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent("LiveEarnings", isDirectory: true)
    }()

    static let overridesURL = root.appendingPathComponent("overrides-v1.json")
    static let historyURL = root.appendingPathComponent("history-v1.json")
    static let pendingDayURL = root.appendingPathComponent("pending-day-v1.json")
    static let calendarItemsURL = root.appendingPathComponent("calendar-items-v1.json")
}
