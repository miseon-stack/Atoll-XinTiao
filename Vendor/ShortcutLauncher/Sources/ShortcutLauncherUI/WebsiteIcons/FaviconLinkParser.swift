import Foundation

public enum FaviconRelationship: Int, Equatable, Sendable {
  case appleTouchIcon = 3
  case icon = 2
  case shortcutIcon = 1
}

public struct FaviconCandidate: Equatable, Sendable {
  public let url: URL
  public let relationship: FaviconRelationship
  public let declaredPixelSize: Int?
  public let declaredMIMEType: String?
  public let documentOrder: Int

  public init(
    url: URL,
    relationship: FaviconRelationship,
    declaredPixelSize: Int?,
    declaredMIMEType: String?,
    documentOrder: Int
  ) {
    self.url = url
    self.relationship = relationship
    self.declaredPixelSize = declaredPixelSize
    self.declaredMIMEType = declaredMIMEType
    self.documentOrder = documentOrder
  }
}

/// A deliberately small, bounded HTML-head parser. It never builds a DOM or
/// executes content and only recognizes the attributes needed for favicon
/// discovery.
public struct FaviconLinkParser: Sendable {
  public init() {}

  public func candidates(
    in htmlData: Data,
    documentURL: URL,
    limit: Int
  ) -> [FaviconCandidate] {
    guard limit > 0 else { return [] }
    let html = decodeHTML(htmlData)
    let head = boundedHead(in: html)
    var candidates: [FaviconCandidate] = []
    var seenURLs = Set<String>()
    var cursor = head.startIndex
    var documentOrder = 0

    while candidates.count < limit,
      let tagRange = nextTag(named: "link", in: head, from: cursor)
    {
      defer { cursor = tagRange.upperBound }
      let tag = String(head[tagRange])
      let attributes = parseAttributes(in: tag)
      guard let relationship = relationship(from: attributes["rel"]),
        let rawHref = attributes["href"].map(decodeBasicEntities(_:)),
        !rawHref.isEmpty,
        let url = URL(string: rawHref, relativeTo: documentURL)?.absoluteURL,
        isHTTPResourceURL(url)
      else {
        documentOrder += 1
        continue
      }

      let mime = attributes["type"]?
        .split(separator: ";", maxSplits: 1)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let normalizedURL = removingFragment(from: url)
      guard seenURLs.insert(normalizedURL.absoluteString).inserted else {
        documentOrder += 1
        continue
      }
      candidates.append(
        FaviconCandidate(
          url: normalizedURL,
          relationship: relationship,
          declaredPixelSize: declaredPixelSize(from: attributes["sizes"]),
          declaredMIMEType: mime?.isEmpty == false ? mime : nil,
          documentOrder: documentOrder
        ))
      documentOrder += 1
    }

    return
      candidates
      .sorted(by: isPreferred(_:over:))
      .prefix(limit)
      .map { $0 }
  }

  private func decodeHTML(_ data: Data) -> String {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
    return String(decoding: data, as: Unicode.UTF8.self)
  }

  private func boundedHead(in html: String) -> Substring {
    let lower = html.lowercased()
    let start: String.Index
    if let headStart = lower.range(of: "<head")?.lowerBound {
      start = headStart
    } else {
      start = html.startIndex
    }
    if let close = lower.range(of: "</head", range: start..<lower.endIndex)?.lowerBound {
      return html[start..<close]
    }
    // Some real pages omit </head>. Stop before body when possible.
    if let body = lower.range(of: "<body", range: start..<lower.endIndex)?.lowerBound {
      return html[start..<body]
    }
    return html[start..<html.endIndex]
  }

  private func nextTag(
    named name: String,
    in text: Substring,
    from start: Substring.Index
  ) -> Range<Substring.Index>? {
    var searchStart = start
    while let open = text.range(
      of: "<\(name)",
      options: [.caseInsensitive],
      range: searchStart..<text.endIndex
    ) {
      let afterName = open.upperBound
      if afterName < text.endIndex {
        let scalar = text[afterName]
        guard scalar.isWhitespace || scalar == ">" || scalar == "/" else {
          searchStart = afterName
          continue
        }
      }

      var index = afterName
      var quote: Character?
      while index < text.endIndex {
        let character = text[index]
        if let currentQuote = quote {
          if character == currentQuote { quote = nil }
        } else if character == "\"" || character == "'" {
          quote = character
        } else if character == ">" {
          return open.lowerBound..<text.index(after: index)
        }
        index = text.index(after: index)
      }
      return nil
    }
    return nil
  }

  private func parseAttributes(in tag: String) -> [String: String] {
    var result: [String: String] = [:]
    var index = tag.startIndex

    func skipSpaces() {
      while index < tag.endIndex, tag[index].isWhitespace {
        index = tag.index(after: index)
      }
    }

    guard let nameEnd = tag[index...].firstIndex(where: { $0.isWhitespace || $0 == ">" })
    else { return result }
    index = nameEnd

    while index < tag.endIndex {
      skipSpaces()
      if index >= tag.endIndex || tag[index] == ">" || tag[index] == "/" { break }
      let nameStart = index
      while index < tag.endIndex {
        let character = tag[index]
        if character.isWhitespace || character == "=" || character == ">" || character == "/" {
          break
        }
        index = tag.index(after: index)
      }
      guard nameStart < index else {
        index = tag.index(after: index)
        continue
      }
      let name = tag[nameStart..<index].lowercased()
      skipSpaces()
      guard index < tag.endIndex, tag[index] == "=" else {
        result[name] = ""
        continue
      }
      index = tag.index(after: index)
      skipSpaces()
      guard index < tag.endIndex else { break }

      let value: String
      if tag[index] == "\"" || tag[index] == "'" {
        let quote = tag[index]
        index = tag.index(after: index)
        let valueStart = index
        while index < tag.endIndex, tag[index] != quote {
          index = tag.index(after: index)
        }
        value = String(tag[valueStart..<index])
        if index < tag.endIndex { index = tag.index(after: index) }
      } else {
        let valueStart = index
        while index < tag.endIndex,
          !tag[index].isWhitespace, tag[index] != ">"
        {
          index = tag.index(after: index)
        }
        value = String(tag[valueStart..<index])
      }
      result[name] = value
    }
    return result
  }

  private func relationship(from rawValue: String?) -> FaviconRelationship? {
    guard let rawValue else { return nil }
    let tokens = Set(
      rawValue.lowercased().split(whereSeparator: \Character.isWhitespace).map(String.init))
    if tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed") {
      return .appleTouchIcon
    }
    guard tokens.contains("icon") else { return nil }
    return tokens.contains("shortcut") ? .shortcutIcon : .icon
  }

  private func declaredPixelSize(from rawValue: String?) -> Int? {
    guard let rawValue else { return nil }
    return rawValue.lowercased().split(whereSeparator: \Character.isWhitespace).compactMap {
      token in
      let parts = token.split(separator: "x", maxSplits: 1)
      guard parts.count == 2,
        let width = Int(parts[0]), let height = Int(parts[1]),
        width > 0, height > 0
      else { return nil }
      return min(width, height)
    }.max()
  }

  private func isPreferred(_ lhs: FaviconCandidate, over rhs: FaviconCandidate) -> Bool {
    let lhsFormat = formatScore(lhs)
    let rhsFormat = formatScore(rhs)
    if lhsFormat != rhsFormat { return lhsFormat > rhsFormat }
    let lhsSize = lhs.declaredPixelSize ?? 0
    let rhsSize = rhs.declaredPixelSize ?? 0
    if lhsSize != rhsSize { return lhsSize > rhsSize }
    if lhs.relationship.rawValue != rhs.relationship.rawValue {
      return lhs.relationship.rawValue > rhs.relationship.rawValue
    }
    return lhs.documentOrder < rhs.documentOrder
  }

  private func formatScore(_ candidate: FaviconCandidate) -> Int {
    switch candidate.declaredMIMEType {
    case "image/png": 4
    case "image/vnd.microsoft.icon", "image/x-icon": 3
    case "image/jpeg", "image/gif": 2
    case nil: 1
    default: 0
    }
  }

  private func isHTTPResourceURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.user == nil,
      components.password == nil,
      components.host?.isEmpty == false
    else { return false }
    return true
  }

  private func removingFragment(from url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.fragment = nil
    return components.url ?? url
  }

  private func decodeBasicEntities(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
      .replacingOccurrences(of: "&#38;", with: "&")
      .replacingOccurrences(of: "&#x26;", with: "&", options: .caseInsensitive)
      .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
      .replacingOccurrences(of: "&#39;", with: "'")
  }
}
