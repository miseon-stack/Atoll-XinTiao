import Foundation

public enum WebURLValidator {
  public static func normalize(_ rawValue: String) throws -> URL {
    guard !rawValue.unicodeScalars.contains(where: {
      CharacterSet.controlCharacters.contains($0)
    }) else {
      throw LauncherError.invalidURL
    }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: {
      CharacterSet.whitespacesAndNewlines.contains($0)
        || CharacterSet.controlCharacters.contains($0)
    }) else {
      throw LauncherError.invalidURL
    }

    let prepared: String
    if let explicitScheme = explicitScheme(in: trimmed) {
      guard explicitScheme == "http" || explicitScheme == "https" else {
        throw LauncherError.unsupportedURLScheme
      }
      prepared = trimmed
    } else {
      prepared = "https://\(trimmed)"
    }

    guard var components = URLComponents(string: prepared),
      let scheme = components.scheme?.lowercased(),
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil
    else {
      throw LauncherError.invalidURL
    }

    guard scheme == "http" || scheme == "https" else {
      throw LauncherError.unsupportedURLScheme
    }

    components.scheme = scheme
    guard let url = components.url else {
      throw LauncherError.invalidURL
    }
    return url
  }

  private static func explicitScheme(in value: String) -> String? {
    guard let colon = value.firstIndex(of: ":"), colon != value.startIndex else {
      return nil
    }

    let prefix = value[..<colon]
    guard !prefix.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
      let first = prefix.unicodeScalars.first,
      CharacterSet.letters.contains(first),
      prefix.dropFirst().unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)
      })
    else {
      return nil
    }

    // `localhost:3000` and `example.com:8443/path` are hosts with ports,
    // not custom URL schemes.
    let suffix = value[value.index(after: colon)...]
    let port = suffix.prefix(while: { $0.isNumber })
    let portRemainder = suffix.dropFirst(port.count)
    if !suffix.hasPrefix("//"), !port.isEmpty,
      portRemainder.isEmpty || ["/", "?", "#"].contains(String(portRemainder.prefix(1)))
    {
      return nil
    }

    return prefix.lowercased()
  }
}
