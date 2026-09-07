/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation

struct AtollManagedCalendarItem: Codable, Hashable, Sendable {
    let id: String
    let isReminder: Bool
    let createdAt: Date
}

private struct AtollCalendarItemDocument: Codable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var items: [AtollManagedCalendarItem] = []
}

actor AtollCalendarItemRegistry {
    static let shared = AtollCalendarItemRegistry()

    private let fileURL: URL
    private var document: AtollCalendarItemDocument?

    init(fileURL: URL = LiveEarningsFileLocations.calendarItemsURL) {
        self.fileURL = fileURL
    }

    func all() throws -> [AtollManagedCalendarItem] {
        try load().items
    }

    func insert(id: String, isReminder: Bool) throws {
        var updated = try load()
        guard !updated.items.contains(where: { $0.id == id }) else { return }
        updated.items.append(
            AtollManagedCalendarItem(id: id, isReminder: isReminder, createdAt: Date())
        )
        try persist(&updated)
    }

    func remove(id: String) throws {
        try remove(ids: [id])
    }

    func remove(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        var updated = try load()
        let oldCount = updated.items.count
        updated.items.removeAll { ids.contains($0.id) }
        guard updated.items.count != oldCount else { return }
        try persist(&updated)
    }

    private func load() throws -> AtollCalendarItemDocument {
        if let document { return document }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = AtollCalendarItemDocument()
            document = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder.atollWorkCalendar.decode(AtollCalendarItemDocument.self, from: data)
        guard decoded.schemaVersion == 1 else { throw WorkCalendarError.unsupportedSchema }
        document = decoded
        return decoded
    }

    private func persist(_ updated: inout AtollCalendarItemDocument) throws {
        updated.revision += 1
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.atollWorkCalendar.encode(updated)
        try data.write(to: fileURL, options: .atomic)
        _ = try JSONDecoder.atollWorkCalendar.decode(
            AtollCalendarItemDocument.self,
            from: Data(contentsOf: fileURL)
        )
        document = updated
    }
}
