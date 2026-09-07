import Foundation

/// User-selectable appearance for the launcher surface.
///
/// This value belongs to the UI layer and is intentionally not persisted in
/// `LauncherConfiguration`. An embedding host may still override the resolved
/// appearance at presentation time.
public enum LauncherAppearance: String, Codable, CaseIterable, Sendable {
  /// Follow the embedding host when it supplies an appearance, otherwise the
  /// current macOS appearance.
  case system
  case light
  case dark

  public var displayName: String {
    switch self {
    case .system: "跟随宿主或系统"
    case .light: "浅色"
    case .dark: "深色"
    }
  }
}

/// Small, privacy-safe preferences document owned by ShortcutLauncherUI.
///
/// Targets, URLs, paths, bookmarks, target names, and hotkeys must never be
/// added to this type. Those values remain in the independently versioned core
/// configuration (currently schema v3).
public struct LauncherUIPreferences: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var onlineWebsiteIconsEnabled: Bool
  public var appearance: LauncherAppearance
  /// Zero means the current inline guide has not been acknowledged.
  public var onboardingVersion: Int

  public init(
    schemaVersion: Int = LauncherUIPreferences.currentSchemaVersion,
    onlineWebsiteIconsEnabled: Bool = true,
    appearance: LauncherAppearance = .system,
    onboardingVersion: Int = 0
  ) {
    self.schemaVersion = schemaVersion
    self.onlineWebsiteIconsEnabled = onlineWebsiteIconsEnabled
    self.appearance = appearance
    self.onboardingVersion = onboardingVersion
  }

  public static let defaults = LauncherUIPreferences()

  public var shouldShowOnboarding: Bool {
    onboardingVersion == 0
  }

  public func validated() throws -> LauncherUIPreferences {
    guard schemaVersion <= Self.currentSchemaVersion else {
      throw LauncherUIPreferencesError.unsupportedFutureSchema(schemaVersion)
    }
    guard schemaVersion == Self.currentSchemaVersion else {
      throw LauncherUIPreferencesError.invalidPreferences
    }
    guard onboardingVersion >= 0 else {
      throw LauncherUIPreferencesError.invalidPreferences
    }
    return self
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case onlineWebsiteIconsEnabled
    case appearance
    case onboardingVersion
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedVersion <= Self.currentSchemaVersion else {
      throw LauncherUIPreferencesError.unsupportedFutureSchema(decodedVersion)
    }
    guard decodedVersion == Self.currentSchemaVersion else {
      throw LauncherUIPreferencesError.invalidPreferences
    }

    schemaVersion = decodedVersion
    onlineWebsiteIconsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .onlineWebsiteIconsEnabled) ?? true
    appearance =
      try container.decodeIfPresent(LauncherAppearance.self, forKey: .appearance) ?? .system
    onboardingVersion = try container.decodeIfPresent(Int.self, forKey: .onboardingVersion) ?? 0
    _ = try validated()
  }
}

public enum LauncherUIPreferencesError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedFutureSchema(Int)
  case invalidPreferences
  case readFailed
  case writeFailed

  public var errorDescription: String? {
    switch self {
    case .unsupportedFutureSchema(let version):
      "界面偏好来自更新版本（schema \(version)），当前版本未作修改"
    case .invalidPreferences:
      "界面偏好格式无效"
    case .readFailed:
      "无法读取界面偏好"
    case .writeFailed:
      "无法保存界面偏好"
    }
  }
}

/// Immutable metadata for one repository load.
public struct LauncherUIPreferencesLoadResult: Equatable, Sendable {
  public let preferences: LauncherUIPreferences
  public let recoveredFromBackup: Bool
  public let recoveredUsingDefaults: Bool
  public let wasFirstRun: Bool

  public init(
    preferences: LauncherUIPreferences,
    recoveredFromBackup: Bool = false,
    recoveredUsingDefaults: Bool = false,
    wasFirstRun: Bool = false
  ) {
    self.preferences = preferences
    self.recoveredFromBackup = recoveredFromBackup
    self.recoveredUsingDefaults = recoveredUsingDefaults
    self.wasFirstRun = wasFirstRun
  }
}

/// Injectable storage boundary for UI-only preferences.
public protocol LauncherUIPreferencesStoring: Sendable {
  var preferencesURL: URL { get }
  var backupURL: URL { get }

  func load() async throws -> LauncherUIPreferencesLoadResult
  func save(_ preferences: LauncherUIPreferences) async throws
  func restore(_ preferences: LauncherUIPreferences) async throws
}
