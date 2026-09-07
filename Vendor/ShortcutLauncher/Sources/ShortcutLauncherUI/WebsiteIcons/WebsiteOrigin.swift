import CryptoKit
import Foundation

public enum WebsiteOriginError: Error, Equatable, Sendable {
  case unsupportedScheme
  case missingHost
  case embeddedCredentials
  case invalidPort
  case invalidURL
}

/// A privacy-safe network origin derived from a website binding.
///
/// Only scheme, normalized host and a non-default port survive conversion.
/// The original path, query, fragment and credentials are never retained.
public struct WebsiteOrigin: Hashable, Sendable {
  public let scheme: String
  public let host: String
  public let port: Int?
  public let normalizedString: String
  public let rootURL: URL

  public init(websiteURL: URL) throws {
    guard let components = URLComponents(url: websiteURL, resolvingAgainstBaseURL: false) else {
      throw WebsiteOriginError.invalidURL
    }
    guard components.user == nil, components.password == nil else {
      throw WebsiteOriginError.embeddedCredentials
    }
    guard let normalizedScheme = components.scheme?.lowercased(),
      normalizedScheme == "http" || normalizedScheme == "https"
    else {
      throw WebsiteOriginError.unsupportedScheme
    }
    guard let canonicalURL = components.url,
      var normalizedHost = canonicalURL.host?.lowercased(),
      !normalizedHost.isEmpty
    else {
      throw WebsiteOriginError.missingHost
    }

    while normalizedHost.hasSuffix("."), normalizedHost.count > 1 {
      normalizedHost.removeLast()
    }
    guard !normalizedHost.isEmpty,
      !normalizedHost.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0)
          || CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw WebsiteOriginError.missingHost
    }

    let explicitPort = components.port
    if let explicitPort, !(1...65_535).contains(explicitPort) {
      throw WebsiteOriginError.invalidPort
    }
    let defaultPort = normalizedScheme == "https" ? 443 : 80

    let normalizedPort = explicitPort == defaultPort ? nil : explicitPort
    var canonicalComponents = URLComponents()
    canonicalComponents.scheme = normalizedScheme
    if normalizedHost.contains(":") {
      canonicalComponents.percentEncodedHost = "[\(normalizedHost)]"
    } else {
      canonicalComponents.host = normalizedHost
    }
    canonicalComponents.port = normalizedPort
    guard let originString = canonicalComponents.string else {
      throw WebsiteOriginError.invalidURL
    }
    canonicalComponents.path = "/"
    guard let rootURL = canonicalComponents.url else {
      throw WebsiteOriginError.invalidURL
    }

    scheme = normalizedScheme
    host = normalizedHost
    port = normalizedPort
    normalizedString = originString
    self.rootURL = rootURL
  }

  public init(_ rawValue: String) throws {
    guard let url = URL(string: rawValue) else { throw WebsiteOriginError.invalidURL }
    try self.init(websiteURL: url)
  }

  public var cacheKey: String {
    Self.sha256Hex(normalizedString)
  }

  public func contains(_ url: URL) -> Bool {
    (try? WebsiteOrigin(websiteURL: url)) == self
  }

  static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { byte in
      String(format: "%02x", byte)
    }.joined()
  }
}
