import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum WebsiteIconImageError: Error, Equatable, Sendable {
  case emptyData
  case byteLimitExceeded
  case unsupportedFormat
  case missingImage
  case invalidDimensions
  case pixelLimitExceeded
  case decodeFailed
  case encodeFailed
}

public protocol WebsiteIconImageDecoding: Sendable {
  func decodeAndNormalize(_ data: Data) throws -> WebsiteIconArtifact
}

/// Validates untrusted image bytes with ImageIO, decodes only the first frame,
/// downsamples before raster allocation, then re-encodes a normalized PNG.
public struct WebsiteIconImageDecoder: WebsiteIconImageDecoding, Sendable {
  private let policy: WebsiteIconFetchPolicy

  public init(policy: WebsiteIconFetchPolicy = .production) {
    self.policy = policy
  }

  public func decodeAndNormalize(_ data: Data) throws -> WebsiteIconArtifact {
    guard !data.isEmpty else { throw WebsiteIconImageError.emptyData }
    guard data.count <= policy.maximumImageBytes else {
      throw WebsiteIconImageError.byteLimitExceeded
    }
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [
          kCGImageSourceShouldCache: false
        ] as CFDictionary)
    else {
      throw WebsiteIconImageError.decodeFailed
    }
    guard CGImageSourceGetCount(source) > 0 else {
      throw WebsiteIconImageError.missingImage
    }
    try validateFormat(source)

    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(
        source,
        0,
        [kCGImageSourceShouldCache: false] as CFDictionary
      ) as? [CFString: Any],
      let width = integerProperty(properties[kCGImagePropertyPixelWidth]),
      let height = integerProperty(properties[kCGImagePropertyPixelHeight]),
      width > 0, height > 0
    else {
      throw WebsiteIconImageError.invalidDimensions
    }
    guard width <= policy.maximumInputPixelDimension,
      height <= policy.maximumInputPixelDimension
    else {
      throw WebsiteIconImageError.pixelLimitExceeded
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: policy.maximumOutputPixelDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw WebsiteIconImageError.decodeFailed
    }

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw WebsiteIconImageError.encodeFailed
    }
    CGImageDestinationAddImage(
      destination, image,
      [
        kCGImageDestinationLossyCompressionQuality: 1.0
      ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw WebsiteIconImageError.encodeFailed
    }

    return WebsiteIconArtifact(
      pngData: output as Data,
      pixelWidth: image.width,
      pixelHeight: image.height
    )
  }

  private func validateFormat(_ source: CGImageSource) throws {
    guard let typeIdentifier = CGImageSourceGetType(source) as String?,
      let type = UTType(typeIdentifier)
    else {
      throw WebsiteIconImageError.unsupportedFormat
    }
    let isICO =
      typeIdentifier == "com.microsoft.ico"
      || typeIdentifier == "com.microsoft.cur"
    guard
      isICO || type.conforms(to: .png) || type.conforms(to: .jpeg)
        || type.conforms(to: .gif)
    else {
      throw WebsiteIconImageError.unsupportedFormat
    }
  }

  private func integerProperty(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let value = value as? Int { return value }
    return nil
  }
}
