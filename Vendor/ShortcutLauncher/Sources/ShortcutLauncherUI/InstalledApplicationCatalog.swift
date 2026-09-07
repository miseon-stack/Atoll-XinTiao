import Foundation
import ShortcutLauncherCore

/// A lightweight, portable description of an installed macOS application.
///
/// The catalog deliberately exposes URLs instead of `NSRunningApplication` or
/// `NSWorkspace` values so callers can persist a normal launcher target without
/// retaining AppKit objects.
public struct ApplicationDescriptor: Identifiable, Hashable, Sendable {
  public let id: String
  public let displayName: String
  public let bundleIdentifier: String?
  public let url: URL
  public let searchAliases: [String]

  public var filename: String {
    url.deletingPathExtension().lastPathComponent
  }

  public init(
    id: String? = nil,
    displayName: String,
    bundleIdentifier: String?,
    url: URL,
    searchAliases: [String] = []
  ) {
    let normalizedURL = Self.normalizedURL(url)
    self.id = id ?? bundleIdentifier
      .flatMap(Self.normalizedBundleIdentifier(_:))
      .map { "bundle:\($0)" }
      ?? "path:\(normalizedURL.path.lowercased())"
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.url = normalizedURL
    self.searchAliases = searchAliases
  }

  private static func normalizedURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func normalizedBundleIdentifier(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
  }
}

/// Sendable metadata returned across the catalog's injectable filesystem seam.
public struct InstalledApplicationMetadata: Equatable, Sendable {
  public let localizedName: String?
  public let bundleIdentifier: String?

  public init(localizedName: String?, bundleIdentifier: String?) {
    self.localizedName = localizedName
    self.bundleIdentifier = bundleIdentifier
  }
}

/// Filesystem boundary used by `InstalledApplicationCatalog`.
///
/// Tests can provide a fixture implementation, and an embedding host can swap
/// in a sandbox-aware implementation without changing catalog behavior.
public protocol InstalledApplicationFileManaging: Sendable {
  func childURLs(at directoryURL: URL) throws -> [URL]
  func isDirectory(at url: URL) -> Bool
  func metadata(forApplicationAt applicationURL: URL) -> InstalledApplicationMetadata
}

/// Host-injectable application index used by the quick-binding search model.
///
/// The asynchronous contract keeps callers independent from the catalog's actor
/// implementation and lets tests provide a fixed application list without ever
/// traversing the user's real application directories.
public protocol InstalledApplicationCataloging: Sendable {
  func applications(forceRefresh: Bool) async -> [ApplicationDescriptor]
  func search(query: String, limit: Int) async -> [ApplicationDescriptor]
  @discardableResult
  func prewarm(forceRefresh: Bool) async -> [ApplicationDescriptor]
  func invalidate() async
}

/// Foundation-backed filesystem implementation used by the shipping app.
public struct DefaultInstalledApplicationFileManager: InstalledApplicationFileManaging,
  @unchecked Sendable
{
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func childURLs(at directoryURL: URL) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
  }

  public func isDirectory(at url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  public func metadata(forApplicationAt applicationURL: URL) -> InstalledApplicationMetadata {
    let bundle = Bundle(url: applicationURL)
    let localizedInfo = bundle?.localizedInfoDictionary
    let info = bundle?.infoDictionary
    let localizedName = Self.nonemptyString(
      localizedInfo?["CFBundleDisplayName"]
        ?? localizedInfo?["CFBundleName"]
        ?? info?["CFBundleDisplayName"]
        ?? info?["CFBundleName"]
    ) ?? Self.filenameWithoutApplicationExtension(
      fileManager.displayName(atPath: applicationURL.path)
    )

    return InstalledApplicationMetadata(
      localizedName: localizedName,
      bundleIdentifier: bundle?.bundleIdentifier
        ?? Self.nonemptyString(info?["CFBundleIdentifier"])
    )
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func filenameWithoutApplicationExtension(_ value: String) -> String {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.lowercased().hasSuffix(".app") else { return name }
    return String(name.dropLast(4))
  }
}

/// Cached installed-application index used by the quick-binding popover.
///
/// This is a non-main actor, so directory traversal and bundle metadata reads
/// do not block SwiftUI's main actor. Each `.app` is treated as a terminal node;
/// plug-ins and helper apps inside its package are intentionally not indexed.
public actor InstalledApplicationCatalog: InstalledApplicationCataloging {
  public static let shared = InstalledApplicationCatalog()

  public static var defaultSearchRoots: [URL] {
    [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true),
    ]
  }

  private let searchRoots: [URL]
  private let fileManager: any InstalledApplicationFileManaging
  private var cachedApplications: [ApplicationDescriptor]?

  public init(
    searchRoots: [URL] = InstalledApplicationCatalog.defaultSearchRoots,
    fileManager: any InstalledApplicationFileManaging = DefaultInstalledApplicationFileManager()
  ) {
    self.searchRoots = searchRoots
    self.fileManager = fileManager
  }

  /// Returns a stable snapshot. Subsequent calls reuse the cached snapshot
  /// unless `forceRefresh` is true or `invalidate()` was called.
  public func applications(forceRefresh: Bool = false) -> [ApplicationDescriptor] {
    if !forceRefresh, let cachedApplications {
      return cachedApplications
    }

    let applications = scanApplications()
    cachedApplications = applications
    return applications
  }

  /// Builds the index on this background actor before the first popover search.
  /// Calling this method repeatedly is inexpensive because it reuses the same
  /// cached snapshot unless an explicit refresh was requested.
  @discardableResult
  public func prewarm(forceRefresh: Bool = false) -> [ApplicationDescriptor] {
    applications(forceRefresh: forceRefresh)
  }

  /// A dependency-free filtering hook for early UI integration. The Core
  /// ranking policy can instead rank the snapshot returned by `applications()`.
  public func search(query: String, limit: Int = 12) -> [ApplicationDescriptor] {
    let allApplications = applications()
    let byID = Dictionary(uniqueKeysWithValues: allApplications.map { ($0.id, $0) })
    let ranked = ApplicationSearchRanking.rank(
      allApplications.map { application in
        ApplicationSearchDocument(
          id: application.id,
          displayName: application.displayName,
          bundleIdentifier: application.bundleIdentifier,
          searchableAliases: application.searchAliases
        )
      },
      for: query
    )
    return Array(ranked.compactMap { byID[$0.id] }.prefix(max(0, limit)))
  }

  public func invalidate() {
    cachedApplications = nil
  }

  private func scanApplications() -> [ApplicationDescriptor] {
    var pendingDirectories = searchRoots.reversed().map(Self.normalizedURL(_:))
    var visitedDirectories = Set<String>()
    var seenApplicationURLs = Set<String>()
    var seenBundleIdentifiers = Set<String>()
    var applications: [ApplicationDescriptor] = []

    while let directoryURL = pendingDirectories.popLast() {
      let directoryKey = Self.normalizedPathKey(directoryURL)
      guard visitedDirectories.insert(directoryKey).inserted else { continue }
      guard let children = try? fileManager.childURLs(at: directoryURL) else { continue }

      for childURL in children.sorted(by: Self.isURLOrderedBefore(_:_:)) {
        let normalizedChildURL = Self.normalizedURL(childURL)
        guard fileManager.isDirectory(at: normalizedChildURL) else { continue }

        if normalizedChildURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
          let urlKey = Self.normalizedPathKey(normalizedChildURL)
          guard seenApplicationURLs.insert(urlKey).inserted else { continue }

          let metadata = fileManager.metadata(forApplicationAt: normalizedChildURL)
          let normalizedBundleIdentifier = metadata.bundleIdentifier
            .flatMap(Self.normalizedBundleIdentifier(_:))
          if let normalizedBundleIdentifier,
             !seenBundleIdentifiers.insert(normalizedBundleIdentifier).inserted {
            continue
          }

          let filename = normalizedChildURL.deletingPathExtension().lastPathComponent
          let displayName = Self.nonempty(metadata.localizedName) ?? filename
          let aliases = Self.makeSearchAliases(
            displayName: displayName,
            filename: filename,
            bundleIdentifier: metadata.bundleIdentifier
          )
          applications.append(ApplicationDescriptor(
            displayName: displayName,
            bundleIdentifier: metadata.bundleIdentifier,
            url: normalizedChildURL,
            searchAliases: aliases
          ))
          continue
        }

        pendingDirectories.append(normalizedChildURL)
      }
    }

    return applications.sorted(by: Self.isOrderedBefore(_:_:))
  }

  private static func makeSearchAliases(
    displayName: String,
    filename: String,
    bundleIdentifier: String?
  ) -> [String] {
    var aliases: [String] = []
    var seen = Set<String>()

    for candidate in [displayName, filename, bundleIdentifier].compactMap({ $0 }) {
      appendSearchAlias(candidate, aliases: &aliases, seen: &seen)
      let latin = candidate
        .applyingTransform(.toLatin, reverse: false)?
        .applyingTransform(.stripDiacritics, reverse: false)
      if let latin {
        appendSearchAlias(latin, aliases: &aliases, seen: &seen)
        let initials = normalizedSearchText(latin)
          .split(separator: " ")
          .compactMap(\.first)
        if !initials.isEmpty {
          appendSearchAlias(String(initials), aliases: &aliases, seen: &seen)
        }
      }
    }

    return aliases
  }

  private static func appendSearchAlias(
    _ candidate: String,
    aliases: inout [String],
    seen: inout Set<String>
  ) {
    let normalized = normalizedSearchText(candidate)
    guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
    aliases.append(normalized)
  }

  private static func normalizedSearchText(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    let scalars = folded.unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
    }
    return String(scalars)
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .lowercased()
  }

  private static func isOrderedBefore(
    _ lhs: ApplicationDescriptor,
    _ rhs: ApplicationDescriptor
  ) -> Bool {
    let lhsName = normalizedSearchText(lhs.displayName)
    let rhsName = normalizedSearchText(rhs.displayName)
    if lhsName != rhsName { return lhsName < rhsName }

    let lhsBundle = lhs.bundleIdentifier.flatMap(normalizedBundleIdentifier(_:)) ?? ""
    let rhsBundle = rhs.bundleIdentifier.flatMap(normalizedBundleIdentifier(_:)) ?? ""
    if lhsBundle != rhsBundle { return lhsBundle < rhsBundle }
    return normalizedPathKey(lhs.url) < normalizedPathKey(rhs.url)
  }

  private static func isURLOrderedBefore(_ lhs: URL, _ rhs: URL) -> Bool {
    normalizedPathKey(lhs) < normalizedPathKey(rhs)
  }

  private static func normalizedURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func normalizedPathKey(_ url: URL) -> String {
    normalizedURL(url).path.precomposedStringWithCanonicalMapping.lowercased()
  }

  private static func normalizedBundleIdentifier(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
