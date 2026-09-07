import Foundation
import ShortcutLauncherCore

public enum CustomWebsiteIconStoreError: Error, Equatable, Sendable {
  case unsupportedManifestVersion
  case corruptManifest
  case assetWriteFailed
}

public protocol CustomWebsiteIconStoring: Sendable {
  func artifact(for bindingID: BindingID, origin: WebsiteOrigin) async -> WebsiteIconArtifact?
}

public protocol CustomWebsiteIconManaging: CustomWebsiteIconStoring {
  @discardableResult
  func store(
    imageData: Data,
    for bindingID: BindingID,
    origin: WebsiteOrigin
  ) async throws -> CustomWebsiteIconMutation

  @discardableResult
  func remove(
    for bindingID: BindingID,
    origin: WebsiteOrigin
  ) async throws -> CustomWebsiteIconMutation?

  func rollback(_ mutation: CustomWebsiteIconMutation) async
  func finalize(_ mutation: CustomWebsiteIconMutation) async
}

/// Opaque, memory-only recovery state that lets the launcher's existing undo
/// coordinator delay destructive asset cleanup until its revision window ends.
public struct CustomWebsiteIconMutation: Sendable {
  public let hadPreviousIcon: Bool
  fileprivate let bindingKey: String
  fileprivate let previousEntry: CustomWebsiteIconManifest.Entry?
  fileprivate let currentEntry: CustomWebsiteIconManifest.Entry?

  fileprivate init(
    bindingKey: String,
    previousEntry: CustomWebsiteIconManifest.Entry?,
    currentEntry: CustomWebsiteIconManifest.Entry?
  ) {
    self.bindingKey = bindingKey
    self.previousEntry = previousEntry
    self.currentEntry = currentEntry
    hadPreviousIcon = previousEntry != nil
  }
}

public struct NoCustomWebsiteIconStore: CustomWebsiteIconStoring, Sendable {
  public init() {}

  public func artifact(
    for bindingID: BindingID,
    origin: WebsiteOrigin
  ) async -> WebsiteIconArtifact? {
    nil
  }
}

/// Versioned, host-injectable storage for user-owned website icon overrides.
/// Automatic-cache cleanup never touches this directory.
public actor CustomWebsiteIconStore: CustomWebsiteIconManaging {
  public static let manifestFileName = "website-icon-assets-v1.json"

  private let directoryURL: URL
  private let manifestURL: URL
  private let decoder: any WebsiteIconImageDecoding
  private let policy: WebsiteIconFetchPolicy
  private let fileManager: FileManager
  private var loadedManifest: CustomWebsiteIconManifest?

  public init(
    directoryURL: URL,
    policy: WebsiteIconFetchPolicy = .production,
    decoder: (any WebsiteIconImageDecoding)? = nil,
    fileManager: FileManager = .default
  ) {
    self.directoryURL = directoryURL
    manifestURL = directoryURL.appendingPathComponent(Self.manifestFileName, isDirectory: false)
    self.policy = policy
    self.decoder = decoder ?? WebsiteIconImageDecoder(policy: policy)
    self.fileManager = fileManager
  }

  public func artifact(
    for bindingID: BindingID,
    origin: WebsiteOrigin
  ) -> WebsiteIconArtifact? {
    do {
      let manifest = try loadManifest()
      let bindingKey = Self.bindingKey(bindingID)
      guard let entry = manifest.entries[bindingKey],
        entry.originKey == origin.cacheKey,
        isSafeAssetFileName(entry.fileName)
      else { return nil }
      let url = directoryURL.appendingPathComponent(entry.fileName, isDirectory: false)
      let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard fileSize <= policy.maximumImageBytes else { return nil }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count <= policy.maximumImageBytes,
        WebsiteIconDigest.sha256Hex(data) == entry.pngDigest
      else { return nil }
      let artifact = try decoder.decodeAndNormalize(data)
      guard artifact.pixelWidth == entry.pixelWidth,
        artifact.pixelHeight == entry.pixelHeight
      else { return nil }
      return artifact
    } catch {
      return nil
    }
  }

  @discardableResult
  public func store(
    imageData: Data,
    for bindingID: BindingID,
    origin: WebsiteOrigin
  ) throws -> CustomWebsiteIconMutation {
    let artifact = try decoder.decodeAndNormalize(imageData)
    var manifest = try loadManifest()
    try ensureDirectory()
    let bindingKey = Self.bindingKey(bindingID)
    let previous = manifest.entries[bindingKey]
    let fileName =
      "asset-\(bindingKey.prefix(16))-\(origin.cacheKey.prefix(16))-\(UUID().uuidString.lowercased()).png"
    let assetURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
    do {
      try WebsiteAtomicFileWriter.write(artifact.pngData, to: assetURL, directoryURL: directoryURL)
    } catch {
      throw CustomWebsiteIconStoreError.assetWriteFailed
    }
    let current = CustomWebsiteIconManifest.Entry(
      originKey: origin.cacheKey,
      fileName: fileName,
      pngDigest: WebsiteIconDigest.sha256Hex(artifact.pngData),
      pixelWidth: artifact.pixelWidth,
      pixelHeight: artifact.pixelHeight,
      updatedAt: Date()
    )
    manifest.entries[bindingKey] = current
    do {
      try saveManifest(manifest)
    } catch {
      try? fileManager.removeItem(at: assetURL)
      throw error
    }
    return CustomWebsiteIconMutation(
      bindingKey: bindingKey,
      previousEntry: previous,
      currentEntry: current
    )
  }

  @discardableResult
  public func remove(
    for bindingID: BindingID,
    origin: WebsiteOrigin
  ) throws -> CustomWebsiteIconMutation? {
    var manifest = try loadManifest()
    let bindingKey = Self.bindingKey(bindingID)
    guard let previous = manifest.entries[bindingKey], previous.originKey == origin.cacheKey else {
      return nil
    }
    manifest.entries.removeValue(forKey: bindingKey)
    try saveManifest(manifest)
    return CustomWebsiteIconMutation(
      bindingKey: bindingKey,
      previousEntry: previous,
      currentEntry: nil
    )
  }

  public func rollback(_ mutation: CustomWebsiteIconMutation) {
    do {
      var manifest = try loadManifest()
      if let previous = mutation.previousEntry {
        manifest.entries[mutation.bindingKey] = previous
      } else {
        manifest.entries.removeValue(forKey: mutation.bindingKey)
      }
      try saveManifest(manifest)
      if let current = mutation.currentEntry,
        current.fileName != mutation.previousEntry?.fileName,
        !manifest.entries.values.contains(where: { $0.fileName == current.fileName })
      {
        try? removeAsset(named: current.fileName)
      }
    } catch {
      // Core configuration undo remains authoritative. An asset rollback
      // failure safely degrades to automatic favicon/fallback presentation.
    }
  }

  public func finalize(_ mutation: CustomWebsiteIconMutation) {
    guard let previous = mutation.previousEntry else { return }
    do {
      let manifest = try loadManifest()
      if !manifest.entries.values.contains(where: { $0.fileName == previous.fileName }) {
        try? removeAsset(named: previous.fileName)
      }
    } catch {
      // User assets are retained rather than destructively guessed at when the
      // manifest is unavailable.
    }
  }

  public func removeOrphanedAssets() {
    do {
      let manifest = try loadManifest()
      let referenced = Set(manifest.entries.values.map(\.fileName))
      guard fileManager.fileExists(atPath: directoryURL.path) else { return }
      let files = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
      for file in files
      where isSafeAssetFileName(file.lastPathComponent)
        && !referenced.contains(file.lastPathComponent)
      {
        try? fileManager.removeItem(at: file)
      }
    } catch {
      // Never delete user assets when references cannot be proven.
    }
  }

  private func loadManifest() throws -> CustomWebsiteIconManifest {
    if let loadedManifest { return loadedManifest }
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      let manifest = CustomWebsiteIconManifest(schemaVersion: 1, entries: [:])
      loadedManifest = manifest
      return manifest
    }
    do {
      let fileSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard fileSize <= Self.maximumManifestBytes else {
        throw CustomWebsiteIconStoreError.corruptManifest
      }
      let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let manifest = try decoder.decode(CustomWebsiteIconManifest.self, from: data)
      guard manifest.schemaVersion == 1 else {
        throw CustomWebsiteIconStoreError.unsupportedManifestVersion
      }
      loadedManifest = manifest
      return manifest
    } catch let error as CustomWebsiteIconStoreError {
      throw error
    } catch {
      throw CustomWebsiteIconStoreError.corruptManifest
    }
  }

  private func saveManifest(_ manifest: CustomWebsiteIconManifest) throws {
    try ensureDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(manifest)
    try WebsiteAtomicFileWriter.write(data, to: manifestURL, directoryURL: directoryURL)
    loadedManifest = manifest
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

  private func removeAsset(named fileName: String) throws {
    guard isSafeAssetFileName(fileName) else { return }
    let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
    if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
  }

  private func isSafeAssetFileName(_ value: String) -> Bool {
    value.hasPrefix("asset-") && value.hasSuffix(".png")
      && !value.contains("/") && !value.contains("\\") && value != "." && value != ".."
  }

  private static func bindingKey(_ bindingID: BindingID) -> String {
    WebsiteIconDigest.sha256Hex(bindingID.rawValue)
  }

  private static let maximumManifestBytes = 4 * 1_024 * 1_024
}

private struct CustomWebsiteIconManifest: Codable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let originKey: String
    let fileName: String
    let pngDigest: String
    let pixelWidth: Int
    let pixelHeight: Int
    let updatedAt: Date
  }

  let schemaVersion: Int
  var entries: [String: Entry]
}
