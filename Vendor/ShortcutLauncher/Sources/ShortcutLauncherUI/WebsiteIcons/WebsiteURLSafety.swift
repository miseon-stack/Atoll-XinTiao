import Darwin
import Foundation

public enum WebsiteResourceKind: Equatable, Sendable {
  case originHTML
  case declaredIcon
  case fallbackIcon
}

public enum WebsiteHostResolution: Equatable, Sendable {
  case publicOnly
  case containsNonPublicAddress
  case unavailable
}

public protocol WebsiteHostAddressResolving: Sendable {
  func resolution(for host: String) -> WebsiteHostResolution
}

public protocol WebsiteURLSafetyChecking: Sendable {
  func allows(
    _ url: URL,
    initialOrigin: WebsiteOrigin,
    resourceKind: WebsiteResourceKind,
    redirectSource: URL?
  ) -> Bool
}

/// Resolves hostnames before URLSession is allowed to connect. This is a
/// defense-in-depth SSRF boundary in addition to rejecting private IP literals.
public struct SystemWebsiteHostAddressResolver: WebsiteHostAddressResolving, Sendable {
  public init() {}

  public func resolution(for host: String) -> WebsiteHostResolution {
    if let literal = WebsiteIPAddress.parse(host) {
      return literal.isPublic ? .publicOnly : .containsNonPublicAddress
    }

    var hints = addrinfo()
    hints.ai_flags = AI_ADDRCONFIG
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var head: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &head)
    guard status == 0, let head else { return .unavailable }
    defer { freeaddrinfo(head) }

    var foundAddress = false
    var cursor: UnsafeMutablePointer<addrinfo>? = head
    while let entry = cursor?.pointee {
      defer { cursor = entry.ai_next }
      guard let address = entry.ai_addr else { continue }
      let parsed: WebsiteIPAddress?
      switch Int32(entry.ai_family) {
      case AF_INET:
        let ipv4 = UnsafeRawPointer(address)
          .assumingMemoryBound(to: sockaddr_in.self)
          .pointee
          .sin_addr
        var copy = ipv4
        parsed = withUnsafeBytes(of: &copy) { rawBuffer in
          WebsiteIPAddress(bytes: Array(rawBuffer.prefix(4)))
        }
      case AF_INET6:
        let ipv6 = UnsafeRawPointer(address)
          .assumingMemoryBound(to: sockaddr_in6.self)
          .pointee
          .sin6_addr
        var copy = ipv6
        parsed = withUnsafeBytes(of: &copy) { rawBuffer in
          WebsiteIPAddress(bytes: Array(rawBuffer.prefix(16)))
        }
      default:
        parsed = nil
      }
      guard let parsed else { continue }
      foundAddress = true
      if !parsed.isPublic { return .containsNonPublicAddress }
    }
    return foundAddress ? .publicOnly : .unavailable
  }
}

public struct DefaultWebsiteURLSafetyChecker: WebsiteURLSafetyChecking, Sendable {
  private let resolver: any WebsiteHostAddressResolving

  public init(
    resolver: any WebsiteHostAddressResolving = SystemWebsiteHostAddressResolver()
  ) {
    self.resolver = resolver
  }

  public func allows(
    _ url: URL,
    initialOrigin: WebsiteOrigin,
    resourceKind: WebsiteResourceKind,
    redirectSource: URL?
  ) -> Bool {
    guard let destination = try? WebsiteOrigin(websiteURL: url) else { return false }
    if initialOrigin.scheme == "https", destination.scheme != "https" { return false }

    if Self.isExplicitLocalHost(initialOrigin.host) {
      // Explicitly bound local sites may only access their exact original
      // origin; declarations and redirects cannot pivot into another service.
      return destination == initialOrigin
    }

    guard resolver.resolution(for: initialOrigin.host) == .publicOnly,
      resolver.resolution(for: destination.host) == .publicOnly
    else { return false }

    if destination != initialOrigin {
      switch resourceKind {
      case .originHTML:
        // Public root pages may perform normal public redirects.
        break
      case .declaredIcon:
        // Cross-origin icons must have been explicitly named by the root page,
        // and every destination in that resource chain remains HTTPS. A later
        // redirect cannot invent a second CDN origin that the page never named.
        guard destination.scheme == "https" else { return false }
        if let redirectSource {
          guard let sourceOrigin = try? WebsiteOrigin(websiteURL: redirectSource),
            sourceOrigin == destination
          else { return false }
        }
      case .fallbackIcon:
        // `/favicon.ico` is synthesized rather than declared, so it cannot
        // pivot to another origin even through a redirect.
        return false
      }
    }
    return true
  }

  private static func isExplicitLocalHost(_ host: String) -> Bool {
    let lowercased = host.lowercased()
    if lowercased == "localhost" || lowercased.hasSuffix(".localhost")
      || lowercased.hasSuffix(".local") || lowercased.hasSuffix(".internal")
      || lowercased.hasSuffix(".home.arpa")
    {
      return true
    }
    return WebsiteIPAddress.parse(lowercased).map { !$0.isPublic } ?? false
  }
}

private struct WebsiteIPAddress {
  let bytes: [UInt8]

  init?(bytes: [UInt8]) {
    guard bytes.count == 4 || bytes.count == 16 else { return nil }
    self.bytes = bytes
  }

  static func parse(_ host: String) -> WebsiteIPAddress? {
    var ipv4 = in_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      var copy = ipv4
      return withUnsafeBytes(of: &copy) { WebsiteIPAddress(bytes: Array($0.prefix(4))) }
    }
    var ipv6 = in6_addr()
    if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
      var copy = ipv6
      return withUnsafeBytes(of: &copy) { WebsiteIPAddress(bytes: Array($0.prefix(16))) }
    }
    return nil
  }

  var isPublic: Bool {
    switch bytes.count {
    case 4: isPublicIPv4
    case 16: isPublicIPv6
    default: false
    }
  }

  private var isPublicIPv4: Bool {
    let a = bytes[0]
    let b = bytes[1]
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100, (64...127).contains(b) { return false }
    if a == 169, b == 254 { return false }
    if a == 172, (16...31).contains(b) { return false }
    if a == 192, b == 168 { return false }
    if a == 192, b == 0 { return false }
    if a == 192, b == 0, bytes[2] == 2 { return false }
    if a == 198, b == 18 || b == 19 { return false }
    if a == 198, b == 51, bytes[2] == 100 { return false }
    if a == 203, b == 0, bytes[2] == 113 { return false }
    return true
  }

  private var isPublicIPv6: Bool {
    if bytes.allSatisfy({ $0 == 0 }) { return false }
    if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
    if bytes[0] == 0xff { return false }
    if bytes[0] & 0xfe == 0xfc { return false }
    if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
    if Array(bytes.prefix(12)) == Array(repeating: 0, count: 10) + [0xff, 0xff] {
      return WebsiteIPAddress(bytes: Array(bytes.suffix(4)))?.isPublic ?? false
    }
    if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
      return false
    }
    // Only globally routable unicast space is accepted automatically.
    return bytes[0] & 0xe0 == 0x20
  }
}
