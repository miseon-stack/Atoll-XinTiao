/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation

protocol HolidayCalendarProviding: Sendable {
    var version: String { get }
    var coveredYears: ClosedRange<Int>? { get }
    func rule(on date: LocalDate) -> HolidayDateRule?
}

struct HolidayCalendarStore: HolidayCalendarProviding, Sendable {
    private let documents: [Int: HolidayCalendarDocument]
    private let rules: [LocalDate: HolidayDateRule]

    var version: String {
        documents.values.sorted { $0.year < $1.year }.map(\.version).joined(separator: "+")
    }

    var coveredYears: ClosedRange<Int>? {
        guard let minimum = documents.keys.min(), let maximum = documents.keys.max() else { return nil }
        return minimum...maximum
    }

    init(bundle: Bundle = .main) {
        var loaded: [HolidayCalendarDocument] = []
        let candidateURLs = (bundle.urls(forResourcesWithExtension: "json", subdirectory: "HolidayCalendars") ?? [])
            + (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []).filter {
                $0.lastPathComponent.hasPrefix("cn-")
            }
        for url in Set(candidateURLs) {
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder.atollWorkCalendar.decode(HolidayCalendarDocument.self, from: data).validated() else {
                continue
            }
            loaded.append(document)
        }
        self.init(documents: loaded)
    }

    init(documents: [HolidayCalendarDocument]) {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.year, $0) })
        rules = Dictionary(uniqueKeysWithValues: documents.flatMap(\.dates).map { ($0.date, $0) })
    }

    func rule(on date: LocalDate) -> HolidayDateRule? { rules[date] }

    func isYearCovered(_ year: Int) -> Bool { documents[year] != nil }
}

extension JSONDecoder {
    static var atollWorkCalendar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var atollWorkCalendar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
