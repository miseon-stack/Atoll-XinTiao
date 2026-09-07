import Foundation

/// A path-free application description used by deterministic search ranking.
public struct ApplicationSearchDocument: Sendable, Hashable, Identifiable {
  public let id: String
  public let displayName: String
  public let bundleIdentifier: String?
  public let searchableAliases: [String]

  public init(
    id: String,
    displayName: String,
    bundleIdentifier: String? = nil,
    searchableAliases: [String] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.searchableAliases = searchableAliases
  }
}

/// Deterministic, dependency-free application search suitable for background use.
public enum ApplicationSearchRanking {
  /// Returns all matches ordered by relevance and stable lexical tie breakers.
  /// An empty query returns every document in stable display-name order.
  public static func rank(
    _ documents: [ApplicationSearchDocument],
    for query: String
  ) -> [ApplicationSearchDocument] {
    let normalizedQuery = normalized(query)
    let compactQuery = compact(normalizedQuery)

    return documents.compactMap { document -> RankedDocument? in
      if compactQuery.isEmpty {
        return RankedDocument(document: document, score: 0)
      }
      guard let score = score(document, normalizedQuery: normalizedQuery, compactQuery: compactQuery)
      else { return nil }
      return RankedDocument(document: document, score: score)
    }.sorted(by: isOrderedBefore).map(\.document)
  }

  /// Exposes a score for diagnostics and focused unit tests. A nil result is
  /// not a match; callers should not persist or interpret the numeric values.
  public static func score(
    _ document: ApplicationSearchDocument,
    for query: String
  ) -> Int? {
    let normalizedQuery = normalized(query)
    let compactQuery = compact(normalizedQuery)
    guard !compactQuery.isEmpty else { return 0 }
    return score(document, normalizedQuery: normalizedQuery, compactQuery: compactQuery)
  }

  private struct RankedDocument {
    let document: ApplicationSearchDocument
    let score: Int
  }

  private static func score(
    _ document: ApplicationSearchDocument,
    normalizedQuery: String,
    compactQuery: String
  ) -> Int? {
    let display = normalized(document.displayName)
    let displayCompact = compact(display)
    if display == normalizedQuery || displayCompact == compactQuery { return 600 }
    if display.hasPrefix(normalizedQuery) || displayCompact.hasPrefix(compactQuery) { return 500 }

    let latinDisplay = latin(document.displayName)
    let latinCompact = compact(latinDisplay)
    let aliasForms = document.searchableAliases.flatMap { alias -> [String] in
      let value = normalized(alias)
      return [value, compact(value), latin(alias), compact(latin(alias))]
    }
    if latinDisplay.hasPrefix(normalizedQuery)
      || latinCompact.hasPrefix(compactQuery)
      || aliasForms.contains(where: {
        $0 == normalizedQuery || $0 == compactQuery
          || $0.hasPrefix(normalizedQuery) || $0.hasPrefix(compactQuery)
      })
    {
      return 400
    }

    let initialForms = [initials(latinDisplay)]
      + document.searchableAliases.map { initials(latin($0)) }
    if initialForms.contains(where: { !$0.isEmpty && $0.hasPrefix(compactQuery) }) {
      return 300
    }

    if display.contains(normalizedQuery)
      || displayCompact.contains(compactQuery)
      || latinDisplay.contains(normalizedQuery)
      || latinCompact.contains(compactQuery)
      || aliasForms.contains(where: {
        $0.contains(normalizedQuery) || $0.contains(compactQuery)
      })
    {
      return 200
    }

    if let bundleIdentifier = document.bundleIdentifier,
      normalized(bundleIdentifier).contains(normalizedQuery)
        || compact(normalized(bundleIdentifier)).contains(compactQuery)
    {
      return 100
    }
    return nil
  }

  private static func isOrderedBefore(_ lhs: RankedDocument, _ rhs: RankedDocument) -> Bool {
    if lhs.score != rhs.score { return lhs.score > rhs.score }
    let leftName = normalized(lhs.document.displayName)
    let rightName = normalized(rhs.document.displayName)
    if leftName != rightName { return leftName < rightName }
    let leftBundle = normalized(lhs.document.bundleIdentifier ?? "")
    let rightBundle = normalized(rhs.document.bundleIdentifier ?? "")
    if leftBundle != rightBundle { return leftBundle < rightBundle }
    return lhs.document.id < rhs.document.id
  }

  private static func normalized(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func latin(_ value: String) -> String {
    let transformed = value.applyingTransform(.toLatin, reverse: false) ?? value
    return normalized(transformed.applyingTransform(.stripDiacritics, reverse: false) ?? transformed)
  }

  private static func compact(_ value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
  }

  private static func initials(_ value: String) -> String {
    value.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .compactMap(\.first)
      .map(String.init)
      .joined()
  }
}
