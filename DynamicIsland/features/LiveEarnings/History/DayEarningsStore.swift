/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation

protocol DayEarningsStoring: Sendable {
    func record(on date: LocalDate) async throws -> DayEarningsRecord?
    func records(in range: ClosedRange<LocalDate>) async throws -> [DayEarningsRecord]
    func upsert(_ record: DayEarningsRecord) async throws
    func removeAll() async throws
}

private struct DayEarningsDocument: Codable, Sendable {
    var schemaVersion = 1
    var startedAt = Date()
    var revision = 0
    var items: [DayEarningsRecord] = []
}

actor DayEarningsStore: DayEarningsStoring {
    static let shared = DayEarningsStore()

    private let fileURL: URL
    private var document: DayEarningsDocument?

    init(fileURL: URL = LiveEarningsFileLocations.historyURL) {
        self.fileURL = fileURL
    }

    func record(on date: LocalDate) throws -> DayEarningsRecord? {
        try load().items.first { $0.date == date }
    }

    func records(in range: ClosedRange<LocalDate>) throws -> [DayEarningsRecord] {
        try load().items.filter { range.contains($0.date) }.sorted { $0.date < $1.date }
    }

    func all() throws -> [DayEarningsRecord] {
        try load().items.sorted { $0.date > $1.date }
    }

    func upsert(_ record: DayEarningsRecord) throws {
        var updated = try load()
        // A completed day is immutable unless a future, explicit correction flow
        // provides a higher record revision.
        if let index = updated.items.firstIndex(where: { $0.date == record.date }) {
            guard record.revision > updated.items[index].revision else { return }
            updated.items[index] = record
        } else {
            updated.items.append(record)
        }
        updated.revision += 1
        updated.items.sort { $0.date < $1.date }
        try write(updated)
        document = updated
    }

    func removeAll() throws {
        let updated = DayEarningsDocument()
        try write(updated)
        document = updated
        try? FileManager.default.removeItem(at: LiveEarningsFileLocations.pendingDayURL)
    }

    private func load() throws -> DayEarningsDocument {
        if let document { return document }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = DayEarningsDocument()
            document = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.atollWorkCalendar.decode(DayEarningsDocument.self, from: data)
            guard decoded.schemaVersion == 1 else { throw WorkCalendarError.unsupportedSchema }
            document = decoded
            return decoded
        } catch let error as WorkCalendarError {
            throw error
        } catch {
            throw WorkCalendarError.corruptedStore
        }
    }

    private func write(_ value: DayEarningsDocument) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.atollWorkCalendar.encode(value)
        try data.write(to: fileURL, options: .atomic)
        _ = try JSONDecoder.atollWorkCalendar.decode(DayEarningsDocument.self, from: Data(contentsOf: fileURL))
    }
}
