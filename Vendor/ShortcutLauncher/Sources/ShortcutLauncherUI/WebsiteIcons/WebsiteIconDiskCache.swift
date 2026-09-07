import CryptoKit
import Darwin
import Foundation

public enum WebsiteIconCacheLookup: Equatable, Sendable {
  case miss
  case positive(WebsiteIconArtifact, isStale: Bool, expiresAt: Date)
  case negative(expiresAt: Date)
}

public protocol WebsiteIconCacheStoring: Sendable {
  func lookup(_ origin: WebsiteOrigin, now: Date) async -> WebsiteIconCacheLookup
  func store(_ artifact: WebsiteIconArtifact, for origin: WebsiteOrigin, now: Date) async
  func storeNegative(for origin: WebsiteOrigin, now: Date) async
  func remove(_ origin: WebsiteOrigin) async
  func removeAll() async
}

/// A bounded derived-data cache. Each entry is a single binary property-list
/// envelope so image bytes and metadata become visible atomically together.
public actor WebsiteIconDiskCache: WebsiteIconCacheStoring {
  private static let schemaVersion = 1
  private let directoryURL: URL
  private let policy: WebsiteIconFetchPolicy
  private let fileManager: FileManager

  public init(
    directoryURL: URL,
    policy: WebsiteIconFetchPolicy = .production,
    fileManager: FileManager = .default
  ) {
    self.directoryURL = directoryURL
    self.policy = policy
    self.fileManager = fileManager
  }

  public func lookup(_ origin: WebsiteOrigin, now: Date = Date()) -> WebsiteIconCacheLookup {
    let url = entryURL(for: origin)
    guard fileManager.fileExists(atPath: url.path) else { return .miss }
    do {
      let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard fileSize <= maximumEnvelopeBytes else {
        try removeItemIfPresent(url)
        return .miss
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      let envelope = try PropertyListDecoder().decode(CacheEnvelope.self, from: data)
      guard envelope.schemaVersion == Self.schemaVersion else {
        try removeItemIfPresent(url)
        return .miss
      }
      try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)

      switch envelope.result {
      case .negative:
        if envelope.expiresAt <= now {
          try removeItemIfPresent(url)
          return .miss
        }
        return .negative(expiresAt: envelope.expiresAt)
      case .positive:
        guard let pngData = envelope.pngData,
          let width = envelope.pixelWidth,
          let height = envelope.pixelHeight,
          width > 0, height > 0,
          width <= policy.maximumOutputPixelDimension,
          height <= policy.maximumOutputPixelDimension,
          pngData.count <= policy.maximumImageBytes,
          envelope.pngDigest == WebsiteIconDigest.sha256Hex(pngData)
        else {
          try removeItemIfPresent(url)
          return .miss
        }
        return .positive(
          WebsiteIconArtifact(pngData: pngData, pixelWidth: width, pixelHeight: height),
          isStale: envelope.expiresAt <= now,
          expiresAt: envelope.expiresAt
        )
      }
    } catch {
      try? removeItemIfPresent(url)
      return .miss
    }
  }

  public func store(
    _ artifact: WebsiteIconArtifact,
    for origin: WebsiteOrigin,
    now: Date = Date()
  ) {
    guard artifact.pixelWidth > 0, artifact.pixelHeight > 0,
      artifact.pixelWidth <= policy.maximumOutputPixelDimension,
      artifact.pixelHeight <= policy.maximumOutputPixelDimension,
      !artifact.pngData.isEmpty,
      artifact.pngData.count <= policy.maximumImageBytes
    else { return }

    let envelope = CacheEnvelope(
      schemaVersion: Self.schemaVersion,
      result: .positive,
      createdAt: now,
      expiresAt: now.addingTimeInterval(policy.successTTL),
      pixelWidth: artifact.pixelWidth,
      pixelHeight: artifact.pixelHeight,
      pngDigest: WebsiteIconDigest.sha256Hex(artifact.pngData),
      pngData: artifact.pngData
    )
    write(envelope, to: entryURL(for: origin), now: now)
    pruneIfNeeded()
  }

  public func storeNegative(for origin: WebsiteOrigin, now: Date = Date()) {
    let envelope = CacheEnvelope(
      schemaVersion: Self.schemaVersion,
      result: .negative,
      createdAt: now,
      expiresAt: now.addingTimeInterval(policy.negativeCacheTTL),
      pixelWidth: nil,
      pixelHeight: nil,
      pngDigest: nil,
      pngData: nil
    )
    write(envelope, to: entryURL(for: origin), now: now)
    pruneIfNeeded()
  }

  public func remove(_ origin: WebsiteOrigin) {
    try? removeItemIfPresent(entryURL(for: origin))
  }

  public func removeAll() {
    guard let files = try? cacheFiles() else { return }
    for file in files { try? removeItemIfPresent(file) }
  }

  public func currentEntryCount() -> Int {
    (try? cacheFiles().count) ?? 0
  }

  public func currentDiskBytes() -> Int {
    guard let files = try? cacheFiles() else { return 0 }
    return files.reduce(into: 0) { total, url in
      total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
  }

  public func fileName(for origin: WebsiteOrigin) -> String {
    entryURL(for: origin).lastPathComponent
  }

  private func write(_ envelope: CacheEnvelope, to url: URL, now: Date) {
    do {
      try ensureDirectory()
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      let data = try encoder.encode(envelope)
      try WebsiteAtomicFileWriter.write(data, to: url, directoryURL: directoryURL)
      try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    } catch {
      // Automatic icons are derived data. A write failure must never escape
      // into binding state or surface as a launcher error.
    }
  }

  private func pruneIfNeeded() {
    guard
      var entries = try? cacheFiles().map({ url -> CacheFile in
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CacheFile(
          url: url,
          modifiedAt: values.contentModificationDate ?? .distantPast,
          bytes: values.fileSize ?? 0
        )
      })
    else { return }

    entries.sort {
      if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
      return $0.url.lastPathComponent < $1.url.lastPathComponent
    }
    var totalBytes = entries.reduce(0) { $0 + $1.bytes }
    var totalCount = entries.count
    for entry in entries {
      guard totalCount > policy.maximumDiskOrigins || totalBytes > policy.maximumDiskBytes else {
        break
      }
      do {
        try removeItemIfPresent(entry.url)
        totalBytes -= entry.bytes
        totalCount -= 1
      } catch {
        continue
      }
    }
  }

  private func cacheFiles() throws -> [URL] {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ).filter { $0.pathExtension == "cache" && $0.lastPathComponent.hasPrefix("origin-") }
  }

  private func ensureDirectory() throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
      return
    }
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private func entryURL(for origin: WebsiteOrigin) -> URL {
    directoryURL.appendingPathComponent("origin-\(origin.cacheKey).cache", isDirectory: false)
  }

  private var maximumEnvelopeBytes: Int {
    let metadataAllowance = 64 * 1_024
    guard policy.maximumImageBytes <= Int.max - metadataAllowance else { return Int.max }
    return policy.maximumImageBytes + metadataAllowance
  }

  private func removeItemIfPresent(_ url: URL) throws {
    if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
  }
}

private struct CacheFile {
  let url: URL
  let modifiedAt: Date
  let bytes: Int
}

private struct CacheEnvelope: Codable {
  enum Result: String, Codable {
    case positive
    case negative
  }

  let schemaVersion: Int
  let result: Result
  let createdAt: Date
  let expiresAt: Date
  let pixelWidth: Int?
  let pixelHeight: Int?
  let pngDigest: String?
  let pngData: Data?
}

enum WebsiteIconDigest {
  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func sha256Hex(_ string: String) -> String {
    sha256Hex(Data(string.utf8))
  }
}

enum WebsiteAtomicFileWriter {
  static func write(_ data: Data, to destinationURL: URL, directoryURL: URL) throws {
    let temporaryURL = directoryURL.appendingPathComponent(
      ".tmp-\(UUID().uuidString)",
      isDirectory: false
    )
    let descriptor = temporaryURL.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var shouldRemoveTemporary = true
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen { Darwin.close(descriptor) }
      if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var written = 0
      while written < rawBuffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          rawBuffer.count - written
        )
        if result < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        written += result
      }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    guard Darwin.close(descriptor) == 0 else { throw POSIXError(.EIO) }
    descriptorIsOpen = false
    guard
      temporaryURL.path.withCString({ temporaryPath in
        destinationURL.path.withCString { destinationPath in
          Darwin.rename(temporaryPath, destinationPath)
        }
      }) == 0
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    shouldRemoveTemporary = false

    let directoryDescriptor = directoryURL.path.withCString { Darwin.open($0, O_RDONLY) }
    if directoryDescriptor >= 0 {
      _ = Darwin.fsync(directoryDescriptor)
      _ = Darwin.close(directoryDescriptor)
    }
  }
}
