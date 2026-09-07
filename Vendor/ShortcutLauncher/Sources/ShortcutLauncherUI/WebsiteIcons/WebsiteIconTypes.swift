import Foundation
import ShortcutLauncherCore

public struct WebsiteIconArtifact: Equatable, Sendable {
  public let pngData: Data
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
    self.pngData = pngData
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

public struct WebsiteIconFallbackDescriptor: Equatable, Sendable {
  public let monogram: String
  /// Stable palette index. The UI maps it to theme-owned semantic colors.
  public let colorSeed: UInt8

  public init(monogram: String, colorSeed: UInt8) {
    self.monogram = monogram
    self.colorSeed = colorSeed
  }

  public init(origin: WebsiteOrigin) {
    let labels = origin.host.split(separator: ".")
    let significant = labels.first(where: { $0.lowercased() != "www" }) ?? labels.first
    let characters = significant?
      .filter { $0.isLetter || $0.isNumber }
      .prefix(2)
      .map(String.init)
      .joined()
      .uppercased()
    monogram = characters?.isEmpty == false ? characters! : "·"
    colorSeed = UInt8(Int(origin.cacheKey.prefix(2), radix: 16) ?? 0) % 12
  }

  public static let generic = WebsiteIconFallbackDescriptor(monogram: "·", colorSeed: 0)
}

public struct WebsiteIconRequest: Equatable, Sendable {
  public enum Reason: String, Equatable, Sendable {
    case newBinding
    case userRefresh
    case explicitBackfill
    /// A cache-only render. It never starts a network request.
    case passiveDisplay
  }

  public let bindingID: BindingID
  public let websiteURL: URL
  public let reason: Reason

  public init(bindingID: BindingID, websiteURL: URL, reason: Reason) {
    self.bindingID = bindingID
    self.websiteURL = websiteURL
    self.reason = reason
  }
}

public enum WebsiteIconResult: Equatable, Sendable {
  case custom(WebsiteIconArtifact)
  case cache(WebsiteIconArtifact, isStale: Bool)
  case downloaded(WebsiteIconArtifact)
  case fallback(WebsiteIconFallbackDescriptor)

  public var presentation: WebsiteIconPresentation {
    switch self {
    case .custom(let artifact): .image(artifact, source: .custom, isStale: false)
    case .cache(let artifact, let isStale):
      .image(artifact, source: .automaticCache, isStale: isStale)
    case .downloaded(let artifact): .image(artifact, source: .downloaded, isStale: false)
    case .fallback(let descriptor): .fallback(descriptor, isLoading: false)
    }
  }
}

public enum WebsiteIconPresentation: Equatable, Sendable {
  public enum Source: String, Equatable, Sendable {
    case custom
    case automaticCache
    case downloaded
  }

  case fallback(WebsiteIconFallbackDescriptor, isLoading: Bool)
  case image(WebsiteIconArtifact, source: Source, isStale: Bool)
}

public struct WebsiteIconUpdate: Equatable, Sendable {
  public let bindingID: BindingID
  public let origin: WebsiteOrigin
  public let result: WebsiteIconResult

  public init(bindingID: BindingID, origin: WebsiteOrigin, result: WebsiteIconResult) {
    self.bindingID = bindingID
    self.origin = origin
    self.result = result
  }
}

public protocol WebsiteIconProviding: Sendable {
  func icon(for request: WebsiteIconRequest) async -> WebsiteIconResult
  func refresh(_ request: WebsiteIconRequest) async -> WebsiteIconResult
  func cancelAll() async
}

public protocol WebsiteIconUpdateStreaming: Sendable {
  func updates() async -> AsyncStream<WebsiteIconUpdate>
}
