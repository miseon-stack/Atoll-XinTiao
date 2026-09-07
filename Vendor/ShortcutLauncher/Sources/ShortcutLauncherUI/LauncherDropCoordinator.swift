import CoreTransferable
import Foundation
import ShortcutLauncherCore
import UniformTypeIdentifiers

extension UTType {
  /// Private launcher-to-launcher payload for moving slots in batch mode.
  ///
  /// A dedicated binary type prevents arbitrary text or external URLs from
  /// being interpreted as an internal slot index.
  public static let shortcutLauncherSlotTransfer = UTType(
    exportedAs: "io.github.miseon-stack.shortcutlauncher.slot-transfer",
    conformingTo: .data
  )
}

/// Versioned payload used only for an internal slot move or swap.
public struct LauncherSlotTransfer: Codable, Equatable, Hashable, Sendable, Transferable {
  public static let currentPayloadVersion = 1

  public let payloadVersion: Int
  public let sourceKeyCode: UInt16

  public init(
    payloadVersion: Int = LauncherSlotTransfer.currentPayloadVersion,
    sourceKeyCode: UInt16
  ) {
    self.payloadVersion = payloadVersion
    self.sourceKeyCode = sourceKeyCode
  }

  public static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .shortcutLauncherSlotTransfer)
  }

  public func validated() throws -> LauncherSlotTransfer {
    guard payloadVersion == Self.currentPayloadVersion else {
      throw LauncherDropError.unsupportedInternalPayloadVersion(payloadVersion)
    }
    guard KeySlotCatalog.allowedKeyCodes.contains(sourceKeyCode) else {
      throw LauncherDropError.invalidSlot
    }
    return self
  }

  public func encodedData() throws -> Data {
    _ = try validated()
    return try JSONEncoder().encode(self)
  }

  public static func decodeValidated(from data: Data) throws -> LauncherSlotTransfer {
    do {
      return try JSONDecoder().decode(Self.self, from: data).validated()
    } catch let error as LauncherDropError {
      throw error
    } catch {
      throw LauncherDropError.invalidInternalPayload
    }
  }
}

/// A single item-provider's representations after platform loading.
///
/// Provenance stays explicit: a file URL loaded as plain text is not promoted
/// to `fileURL`. This is the boundary that rejects file-text masquerading.
public struct LauncherDropItem: Equatable, Sendable {
  public var internalSlotData: Data?
  public var fileURL: URL?
  public var url: URL?
  public var plainText: String?

  public init(
    internalSlotData: Data? = nil,
    fileURL: URL? = nil,
    url: URL? = nil,
    plainText: String? = nil
  ) {
    self.internalSlotData = internalSlotData
    self.fileURL = fileURL
    self.url = url
    self.plainText = plainText
  }

  public static func internalSlot(_ transfer: LauncherSlotTransfer) throws -> LauncherDropItem {
    LauncherDropItem(internalSlotData: try transfer.encodedData())
  }

  public static func fileURL(_ url: URL) -> LauncherDropItem {
    LauncherDropItem(fileURL: url)
  }

  public static func webURL(_ url: URL) -> LauncherDropItem {
    LauncherDropItem(url: url)
  }

  public static func plainText(_ value: String) -> LauncherDropItem {
    LauncherDropItem(plainText: value)
  }
}

public enum ResolvedLauncherDrop: Equatable, Sendable {
  case internalSlot(LauncherSlotTransfer)
  case externalTarget(LaunchTarget)
}

public struct LauncherDropFileMetadata: Equatable, Sendable {
  public let exists: Bool
  public let isDirectory: Bool
  public let isApplication: Bool
  public let displayName: String
  public let normalizedURL: URL

  public init(
    exists: Bool,
    isDirectory: Bool,
    isApplication: Bool,
    displayName: String,
    normalizedURL: URL
  ) {
    self.exists = exists
    self.isDirectory = isDirectory
    self.isApplication = isApplication
    self.displayName = displayName
    self.normalizedURL = normalizedURL
  }
}

/// Injectable filesystem seam so drop classification tests never inspect a
/// user's real Finder targets.
public protocol LauncherDropFileInspecting: Sendable {
  func metadata(forFileURL url: URL) -> LauncherDropFileMetadata
}

public struct DefaultLauncherDropFileInspector: LauncherDropFileInspecting,
  @unchecked Sendable
{
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func metadata(forFileURL url: URL) -> LauncherDropFileMetadata {
    let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(
      atPath: normalizedURL.path,
      isDirectory: &isDirectory
    )
    let hasApplicationExtension =
      normalizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    let packageType =
      Bundle(url: normalizedURL)?
      .object(forInfoDictionaryKey: "CFBundlePackageType") as? String
    let isApplication =
      exists
      && isDirectory.boolValue
      && hasApplicationExtension
      && packageType == "APPL"
    let displayedFilename = fileManager.displayName(atPath: normalizedURL.path)
    let displayName: String
    if isApplication, displayedFilename.lowercased().hasSuffix(".app") {
      displayName = String(displayedFilename.dropLast(4))
    } else {
      displayName = displayedFilename
    }

    return LauncherDropFileMetadata(
      exists: exists,
      isDirectory: isDirectory.boolValue,
      isApplication: isApplication,
      displayName: displayName,
      normalizedURL: normalizedURL
    )
  }
}

public enum LauncherDropError: Error, LocalizedError, Equatable, Sendable {
  case noTarget
  case multipleTargets
  case ambiguousRepresentations
  case unsupportedRepresentation
  case invalidInternalPayload
  case unsupportedInternalPayloadVersion(Int)
  case invalidSlot
  case missingSourceBinding
  case sameSlot
  case targetUnavailable
  case invalidApplication
  case unsupportedURLScheme
  case invalidURL

  public var errorDescription: String? {
    switch self {
    case .noTarget: "没有可绑定的拖放目标"
    case .multipleTargets: "一次只能拖入一个目标"
    case .ambiguousRepresentations: "拖入内容包含多个不一致的目标"
    case .unsupportedRepresentation: "不支持这种拖放内容"
    case .invalidInternalPayload: "槽位拖放数据无效"
    case .unsupportedInternalPayloadVersion: "槽位拖放数据来自不兼容的版本"
    case .invalidSlot: "目标键位无效"
    case .missingSourceBinding: "被移动的槽位已不再包含绑定"
    case .sameSlot: "目标已经位于这个键位"
    case .targetUnavailable: "拖入的本地目标不存在或当前不可访问"
    case .invalidApplication: "拖入的项目不是有效的 macOS 应用"
    case .unsupportedURLScheme: "只支持 HTTP 或 HTTPS 网站"
    case .invalidURL: "拖入的网址无效"
    }
  }
}

/// Pure, deterministic resolver for item-provider representations.
public struct DropTargetResolver: Sendable {
  private let fileInspector: any LauncherDropFileInspecting

  public init(
    fileInspector: any LauncherDropFileInspecting = DefaultLauncherDropFileInspector()
  ) {
    self.fileInspector = fileInspector
  }

  public func resolve(items: [LauncherDropItem]) throws -> ResolvedLauncherDrop {
    guard !items.isEmpty else { throw LauncherDropError.noTarget }
    guard items.count == 1 else { throw LauncherDropError.multipleTargets }
    return try resolve(item: items[0])
  }

  public func resolve(item: LauncherDropItem) throws -> ResolvedLauncherDrop {
    let hasExternalRepresentation = item.fileURL != nil || item.url != nil || item.plainText != nil
    if let internalSlotData = item.internalSlotData {
      guard !hasExternalRepresentation else {
        throw LauncherDropError.ambiguousRepresentations
      }
      return .internalSlot(try LauncherSlotTransfer.decodeValidated(from: internalSlotData))
    }

    if let fileURL = item.fileURL {
      guard fileURL.isFileURL else { throw LauncherDropError.unsupportedRepresentation }
      if let url = item.url, !Self.areEquivalent(fileURL, url) {
        throw LauncherDropError.ambiguousRepresentations
      }
      if let plainText = item.plainText,
        !Self.text(plainText, represents: fileURL)
      {
        throw LauncherDropError.ambiguousRepresentations
      }
      return .externalTarget(try localTarget(for: fileURL))
    }

    if let url = item.url {
      guard !url.isFileURL else {
        // A local target must originate from public.file-url, not a generic URL
        // or text representation.
        throw LauncherDropError.unsupportedRepresentation
      }
      if let plainText = item.plainText, !Self.text(plainText, represents: url) {
        throw LauncherDropError.ambiguousRepresentations
      }
      return .externalTarget(try webTarget(for: url))
    }

    if let plainText = item.plainText {
      return .externalTarget(try webTarget(forStrictHTTPText: plainText))
    }

    throw LauncherDropError.unsupportedRepresentation
  }

  private func localTarget(for url: URL) throws -> LaunchTarget {
    let metadata = fileInspector.metadata(forFileURL: url)
    guard metadata.exists else { throw LauncherDropError.targetUnavailable }

    let kind: LaunchTargetKind
    if metadata.normalizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
      guard metadata.isApplication else { throw LauncherDropError.invalidApplication }
      kind = .application
    } else if metadata.isDirectory {
      kind = .folder
    } else {
      kind = .file
    }

    let fallbackName = metadata.normalizedURL.lastPathComponent
    let displayName = metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return LaunchTarget(
      kind: kind,
      displayName: displayName.isEmpty ? fallbackName : displayName,
      lastKnownURL: metadata.normalizedURL,
      bookmarkData: nil
    )
  }

  private func webTarget(for url: URL) throws -> LaunchTarget {
    guard let scheme = url.scheme?.lowercased() else {
      throw LauncherDropError.invalidURL
    }
    guard scheme == "http" || scheme == "https" else {
      throw LauncherDropError.unsupportedURLScheme
    }
    do {
      let normalized = try WebURLValidator.normalize(url.absoluteString)
      guard let host = normalized.host, !host.isEmpty else {
        throw LauncherDropError.invalidURL
      }
      return LaunchTarget(
        kind: .web,
        displayName: Self.webDisplayName(for: normalized),
        lastKnownURL: normalized,
        bookmarkData: nil
      )
    } catch let error as LauncherDropError {
      throw error
    } catch let error as LauncherError {
      switch error {
      case .unsupportedURLScheme: throw LauncherDropError.unsupportedURLScheme
      default: throw LauncherDropError.invalidURL
      }
    } catch {
      throw LauncherDropError.invalidURL
    }
  }

  private func webTarget(forStrictHTTPText value: String) throws -> LaunchTarget {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased() else {
      throw LauncherDropError.unsupportedRepresentation
    }
    guard scheme == "http" || scheme == "https" else {
      // In particular, never promote file:, javascript:, data:, or a local path
      // from text into an executable launcher target.
      throw LauncherDropError.unsupportedURLScheme
    }
    return try webTarget(for: parsed)
  }

  private static func webDisplayName(for url: URL) -> String {
    guard let host = url.host else { return url.absoluteString }
    if let port = url.port { return "\(host):\(port)" }
    return host
  }

  private static func areEquivalent(_ lhs: URL, _ rhs: URL) -> Bool {
    if lhs.isFileURL || rhs.isFileURL {
      return lhs.isFileURL && rhs.isFileURL
        && lhs.standardizedFileURL.resolvingSymlinksInPath()
          == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
    return lhs.absoluteString == rhs.absoluteString
  }

  private static func text(_ value: String, represents url: URL) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if url.isFileURL {
      return trimmed == url.absoluteString || trimmed == url.path
    }
    guard let textURL = URL(string: trimmed) else { return false }
    return areEquivalent(textURL, url)
  }
}

public enum LauncherDropProposal: Equatable, Sendable {
  case bind(target: LaunchTarget, destinationKeyCode: UInt16)
  case replace(
    target: LaunchTarget,
    destinationKeyCode: UInt16,
    replacedBindingID: BindingID
  )
  case move(sourceKeyCode: UInt16, destinationKeyCode: UInt16)
  case swap(sourceKeyCode: UInt16, destinationKeyCode: UInt16)

  public var requiresReplacementConfirmation: Bool {
    if case .replace = self { return true }
    return false
  }
}

/// Converts a validated drop into a side-effect-free plan. The caller remains
/// responsible for presenting replacement confirmation and routing the chosen
/// proposal through the existing revision-aware commit transaction.
public struct LauncherDropCoordinator: Sendable {
  private let resolver: DropTargetResolver

  public init(resolver: DropTargetResolver = DropTargetResolver()) {
    self.resolver = resolver
  }

  public func prepare(
    items: [LauncherDropItem],
    destinationKeyCode: UInt16,
    bindings: [UInt16: BindingRecord]
  ) throws -> LauncherDropProposal {
    guard KeySlotCatalog.allowedKeyCodes.contains(destinationKeyCode) else {
      throw LauncherDropError.invalidSlot
    }

    switch try resolver.resolve(items: items) {
    case .externalTarget(let target):
      if let existing = bindings[destinationKeyCode] {
        return .replace(
          target: target,
          destinationKeyCode: destinationKeyCode,
          replacedBindingID: existing.id
        )
      }
      return .bind(target: target, destinationKeyCode: destinationKeyCode)

    case .internalSlot(let transfer):
      let sourceKeyCode = transfer.sourceKeyCode
      guard sourceKeyCode != destinationKeyCode else { throw LauncherDropError.sameSlot }
      guard bindings[sourceKeyCode] != nil else {
        throw LauncherDropError.missingSourceBinding
      }
      if bindings[destinationKeyCode] == nil {
        return .move(
          sourceKeyCode: sourceKeyCode,
          destinationKeyCode: destinationKeyCode
        )
      }
      return .swap(
        sourceKeyCode: sourceKeyCode,
        destinationKeyCode: destinationKeyCode
      )
    }
  }
}
