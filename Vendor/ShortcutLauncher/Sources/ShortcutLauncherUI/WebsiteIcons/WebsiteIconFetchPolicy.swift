import Foundation

/// All resource, time and cache limits for website icons live in one injectable
/// value so production and deterministic fixture tests cannot drift apart.
public struct WebsiteIconFetchPolicy: Equatable, Sendable {
  public var maximumHTMLBytes: Int
  public var maximumDiscoveredCandidates: Int
  public var maximumDownloadedCandidates: Int
  public var maximumImageBytes: Int
  public var maximumRedirects: Int
  public var totalTimeout: TimeInterval
  public var maximumConcurrentNetworkRequests: Int
  public var maximumInputPixelDimension: Int
  public var maximumOutputPixelDimension: Int
  public var maximumMemoryOrigins: Int
  public var maximumDiskBytes: Int
  public var maximumDiskOrigins: Int
  public var successTTL: TimeInterval
  public var negativeCacheTTL: TimeInterval

  public init(
    maximumHTMLBytes: Int = 256 * 1_024,
    maximumDiscoveredCandidates: Int = 8,
    maximumDownloadedCandidates: Int = 3,
    maximumImageBytes: Int = 1_024 * 1_024,
    maximumRedirects: Int = 3,
    totalTimeout: TimeInterval = 6,
    maximumConcurrentNetworkRequests: Int = 3,
    maximumInputPixelDimension: Int = 4_096,
    maximumOutputPixelDimension: Int = 256,
    maximumMemoryOrigins: Int = 64,
    maximumDiskBytes: Int = 20 * 1_024 * 1_024,
    maximumDiskOrigins: Int = 256,
    successTTL: TimeInterval = 7 * 24 * 60 * 60,
    negativeCacheTTL: TimeInterval = 6 * 60 * 60
  ) {
    self.maximumHTMLBytes = max(1, maximumHTMLBytes)
    self.maximumDiscoveredCandidates = max(1, maximumDiscoveredCandidates)
    self.maximumDownloadedCandidates = max(1, maximumDownloadedCandidates)
    self.maximumImageBytes = max(1, maximumImageBytes)
    self.maximumRedirects = max(0, maximumRedirects)
    self.totalTimeout = max(0.1, totalTimeout)
    self.maximumConcurrentNetworkRequests = max(1, maximumConcurrentNetworkRequests)
    self.maximumInputPixelDimension = max(1, maximumInputPixelDimension)
    self.maximumOutputPixelDimension = max(1, maximumOutputPixelDimension)
    self.maximumMemoryOrigins = max(1, maximumMemoryOrigins)
    self.maximumDiskBytes = max(1, maximumDiskBytes)
    self.maximumDiskOrigins = max(1, maximumDiskOrigins)
    self.successTTL = max(1, successTTL)
    self.negativeCacheTTL = max(1, negativeCacheTTL)
  }

  public static let production = WebsiteIconFetchPolicy()
}
