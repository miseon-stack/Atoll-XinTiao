import CoreGraphics
import Foundation
import ImageIO
import ShortcutLauncherCore
import UniformTypeIdentifiers
import XCTest

@testable import ShortcutLauncherUI

final class WebsiteIconStorageImageTests: XCTestCase {
  func testImageDecoderDownsamplesAndNormalizesPNG() throws {
    let source = try makeImageData(width: 512, height: 256, type: .png)
    let decoder = WebsiteIconImageDecoder(
      policy: WebsiteIconFetchPolicy(
        maximumImageBytes: source.count + 1,
        maximumOutputPixelDimension: 128
      ))

    let artifact = try decoder.decodeAndNormalize(source)

    XCTAssertEqual(artifact.pixelWidth, 128)
    XCTAssertEqual(artifact.pixelHeight, 64)
    let decodedType =
      CGImageSourceCreateWithData(artifact.pngData as CFData, nil)
      .flatMap(CGImageSourceGetType) as String?
    XCTAssertEqual(decodedType, UTType.png.identifier)
  }

  func testImageDecoderRejectsUnsupportedFormatAndPixelBomb() throws {
    let bytePolicy = WebsiteIconFetchPolicy(maximumImageBytes: 3)
    XCTAssertThrowsError(
      try WebsiteIconImageDecoder(policy: bytePolicy).decodeAndNormalize(Data([1, 2, 3, 4]))
    ) {
      XCTAssertEqual($0 as? WebsiteIconImageError, .byteLimitExceeded)
    }

    let tiff = try makeImageData(width: 8, height: 8, type: .tiff)
    XCTAssertThrowsError(try WebsiteIconImageDecoder().decodeAndNormalize(tiff)) {
      XCTAssertEqual($0 as? WebsiteIconImageError, .unsupportedFormat)
    }

    let oversized = try makeImageData(width: 257, height: 1, type: .png)
    let policy = WebsiteIconFetchPolicy(
      maximumImageBytes: oversized.count + 1,
      maximumInputPixelDimension: 256
    )
    XCTAssertThrowsError(try WebsiteIconImageDecoder(policy: policy).decodeAndNormalize(oversized))
    {
      XCTAssertEqual($0 as? WebsiteIconImageError, .pixelLimitExceeded)
    }
  }

  func testImageDecoderAcceptsFrozenRasterFormatsAndAlwaysOutputsPNG() throws {
    for type in [UTType.png, .jpeg, .gif, .ico] {
      let source = try makeImageData(width: 32, height: 32, type: type)
      let decoder = WebsiteIconImageDecoder(
        policy: WebsiteIconFetchPolicy(maximumImageBytes: source.count + 1)
      )

      let artifact = try decoder.decodeAndNormalize(source)
      let outputType =
        CGImageSourceCreateWithData(artifact.pngData as CFData, nil)
        .flatMap(CGImageSourceGetType) as String?

      XCTAssertEqual(outputType, UTType.png.identifier, "Failed format: \(type.identifier)")
      XCTAssertGreaterThan(artifact.pixelWidth, 0)
      XCTAssertGreaterThan(artifact.pixelHeight, 0)
    }
  }

  func testDiskCacheUsesHashedNamesAndSupportsFreshStaleNegativeAndExpiry() async throws {
    let fixture = try WebsiteIconTemporaryDirectory()
    defer { fixture.remove() }
    let policy = WebsiteIconFetchPolicy(successTTL: 10, negativeCacheTTL: 5)
    let cache = WebsiteIconDiskCache(directoryURL: fixture.url, policy: policy)
    let origin = try WebsiteOrigin("https://private.example/account?token=secret")
    let artifact = WebsiteIconArtifact(
      pngData: Data([0x89, 0x50, 0x4e, 0x47]),
      pixelWidth: 16,
      pixelHeight: 16
    )
    let epoch = Date(timeIntervalSince1970: 1_000)

    await cache.store(artifact, for: origin, now: epoch)
    let fresh = await cache.lookup(origin, now: epoch.addingTimeInterval(9))
    let stale = await cache.lookup(origin, now: epoch.addingTimeInterval(11))
    XCTAssertEqual(
      fresh,
      .positive(artifact, isStale: false, expiresAt: epoch.addingTimeInterval(10))
    )
    XCTAssertEqual(
      stale,
      .positive(artifact, isStale: true, expiresAt: epoch.addingTimeInterval(10))
    )
    let fileName = await cache.fileName(for: origin)
    XCTAssertFalse(fileName.contains("private"))
    XCTAssertFalse(fileName.contains("example"))
    XCTAssertFalse(fileName.contains("token"))

    await cache.storeNegative(for: origin, now: epoch)
    let negative = await cache.lookup(origin, now: epoch.addingTimeInterval(4))
    let expired = await cache.lookup(origin, now: epoch.addingTimeInterval(6))
    XCTAssertEqual(negative, .negative(expiresAt: epoch.addingTimeInterval(5)))
    XCTAssertEqual(expired, .miss)
  }

  func testDiskCachePrunesLeastRecentlyUsedAndRebuildsCorruption() async throws {
    let fixture = try WebsiteIconTemporaryDirectory()
    defer { fixture.remove() }
    let policy = WebsiteIconFetchPolicy(
      maximumDiskBytes: 1_000_000,
      maximumDiskOrigins: 2
    )
    let cache = WebsiteIconDiskCache(directoryURL: fixture.url, policy: policy)
    let origins = try [
      WebsiteOrigin("https://one.example"),
      WebsiteOrigin("https://two.example"),
      WebsiteOrigin("https://three.example"),
    ]
    let artifact = WebsiteIconArtifact(
      pngData: Data([1, 2, 3, 4]),
      pixelWidth: 8,
      pixelHeight: 8
    )
    for (offset, origin) in origins.enumerated() {
      await cache.store(
        artifact,
        for: origin,
        now: Date(timeIntervalSince1970: TimeInterval(100 + offset))
      )
    }

    let entryCount = await cache.currentEntryCount()
    let pruned = await cache.lookup(origins[0], now: Date(timeIntervalSince1970: 110))
    XCTAssertEqual(entryCount, 2)
    XCTAssertEqual(pruned, .miss)

    let secondFile = await cache.fileName(for: origins[1])
    try Data("corrupt".utf8).write(to: fixture.url.appendingPathComponent(secondFile))
    let corrupt = await cache.lookup(origins[1], now: Date(timeIntervalSince1970: 110))
    let remainingEntryCount = await cache.currentEntryCount()
    XCTAssertEqual(corrupt, .miss)
    XCTAssertEqual(remainingEntryCount, 1)
  }

  func testCustomStoreUsesSafeManifestAndSupportsRemoveRollbackFinalize() async throws {
    let fixture = try WebsiteIconTemporaryDirectory()
    defer { fixture.remove() }
    let imageData = try makeImageData(width: 64, height: 64, type: .png)
    let policy = WebsiteIconFetchPolicy()
    let store = CustomWebsiteIconStore(directoryURL: fixture.url, policy: policy)
    let bindingID = BindingID(rawValue: "https://private.example/account?token=secret")
    let origin = try WebsiteOrigin("https://private.example/account?token=secret")

    let insertion = try await store.store(
      imageData: imageData,
      for: bindingID,
      origin: origin
    )
    XCTAssertFalse(insertion.hadPreviousIcon)
    let storedArtifact = await store.artifact(for: bindingID, origin: origin)
    let mismatchedArtifact = await store.artifact(
      for: bindingID,
      origin: try WebsiteOrigin("https://other.example")
    )
    XCTAssertNotNil(storedArtifact)
    XCTAssertNil(mismatchedArtifact)

    let manifestData = try Data(
      contentsOf: fixture.url.appendingPathComponent(
        CustomWebsiteIconStore.manifestFileName
      ))
    let manifestText = String(decoding: manifestData, as: UTF8.self)
    XCTAssertFalse(manifestText.contains("private.example"))
    XCTAssertFalse(manifestText.contains("token=secret"))

    let optionalRemoval = try await store.remove(for: bindingID, origin: origin)
    let removal = try XCTUnwrap(optionalRemoval)
    let removedArtifact = await store.artifact(for: bindingID, origin: origin)
    XCTAssertNil(removedArtifact)
    await store.rollback(removal)
    let rolledBackArtifact = await store.artifact(for: bindingID, origin: origin)
    XCTAssertNotNil(rolledBackArtifact)

    let optionalFinalRemoval = try await store.remove(for: bindingID, origin: origin)
    let finalRemoval = try XCTUnwrap(optionalFinalRemoval)
    await store.finalize(finalRemoval)
    let finalizedArtifact = await store.artifact(for: bindingID, origin: origin)
    XCTAssertNil(finalizedArtifact)
    let pngFiles = try FileManager.default.contentsOfDirectory(
      at: fixture.url, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "png" }
    XCTAssertTrue(pngFiles.isEmpty)
  }

  private func makeImageData(width: Int, height: Int, type: UTType) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        output,
        type.identifier as CFString,
        1,
        nil
      ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }
}

private final class WebsiteIconTemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WebsiteIconTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}
