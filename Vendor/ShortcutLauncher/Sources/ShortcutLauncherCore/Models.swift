import CryptoKit
import Foundation

public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let command = ModifierSet(rawValue: 1 << 0)
  public static let option = ModifierSet(rawValue: 1 << 1)
  public static let control = ModifierSet(rawValue: 1 << 2)
  public static let shift = ModifierSet(rawValue: 1 << 3)
  public static let defaultDirect: ModifierSet = [.command, .option]
  public static let supported: ModifierSet = [.command, .option, .control, .shift]

  public var displayName: String {
    var parts: [String] = []
    if contains(.control) { parts.append("⌃") }
    if contains(.option) { parts.append("⌥") }
    if contains(.shift) { parts.append("⇧") }
    if contains(.command) { parts.append("⌘") }
    return parts.joined()
  }
}

public struct HotkeyDefinition: Codable, Hashable, Sendable {
  public var keyCode: UInt16
  public var modifiers: ModifierSet

  public init(keyCode: UInt16, modifiers: ModifierSet) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  public var displayName: String {
    "\(modifiers.displayName)\(KeySlotCatalog.label(for: keyCode))"
  }

  public func validate() throws {
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else {
      throw LauncherError.invalidHotkey("主键不在支持的 38 键范围内")
    }
    guard !modifiers.isEmpty else {
      throw LauncherError.invalidHotkey("快捷键至少需要一个修饰键")
    }
    guard modifiers != .shift else {
      throw LauncherError.invalidHotkey("不允许只使用 Shift 作为修饰键")
    }
    guard modifiers.subtracting(.supported).isEmpty else {
      throw LauncherError.invalidHotkey("包含不支持的修饰键")
    }
  }
}

public struct BindingID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
  public let rawValue: String
  public var id: String { rawValue }

  public init(rawValue: String) { self.rawValue = rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static func make() -> BindingID {
    BindingID(rawValue: UUID().uuidString.lowercased())
  }

  public static func legacy(keyCode: UInt16) -> BindingID {
    BindingID(rawValue: "legacy-v2-\(keyCode)")
  }

  /// Stable identity exposed at host-facing boundaries.
  ///
  /// Schema v3 historically allowed any non-empty identifier, and some hosts
  /// used a URL or local path as that value. Persisted identifiers must remain
  /// byte-for-byte compatible, but resource locations must not escape through
  /// snapshots or telemetry. Values that resemble private locations are
  /// therefore represented by a deterministic, non-reversible alias.
  public var hostSafeProjection: BindingID {
    guard requiresHostPrivacyProjection else { return self }
    let digest = SHA256.hash(data: Data(rawValue.utf8))
    let hexDigest = digest.map { byte in
      let value = String(byte, radix: 16)
      return value.count == 1 ? "0\(value)" : value
    }.joined()
    return BindingID(rawValue: "opaque-sha256-\(hexDigest)")
  }

  private var requiresHostPrivacyProjection: Bool {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()
    let hasURIScheme: Bool = {
      guard let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex else {
        return false
      }
      let scheme = trimmed[..<colon]
      guard let first = scheme.unicodeScalars.first,
        CharacterSet.letters.contains(first)
      else { return false }
      return scheme.dropFirst().unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)
      }
    }()
    return rawValue.utf8.count > 128
      || rawValue.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
      // The projection namespace is reserved. A historical raw identifier may
      // legitimately use this spelling, so project it again rather than
      // allowing it to impersonate another binding's public identifier.
      || lowercased.hasPrefix("opaque-sha256-")
      || hasURIScheme
      || lowercased.contains("://")
      || lowercased.hasPrefix("file:")
      || lowercased.hasPrefix("www.")
      || lowercased.hasPrefix("~")
      || lowercased.contains("/")
      || lowercased.contains("\\")
      || lowercased.contains("?")
      || lowercased.contains("#")
      || lowercased.contains("%2f")
      || lowercased.contains("%5c")
  }
}

public enum HotkeyID: Hashable, Sendable {
  case panel
  case direct(bindingID: BindingID)
}

public enum LaunchTargetKind: String, Codable, CaseIterable, Sendable {
  case application
  case file
  case folder
  case web

  public var displayName: String {
    switch self {
    case .application: "应用"
    case .file: "文件"
    case .folder: "文件夹"
    case .web: "网页"
    }
  }
}

public struct LaunchTarget: Codable, Equatable, Sendable {
  public var kind: LaunchTargetKind
  public var displayName: String
  public var lastKnownURL: URL
  public var bookmarkData: Data?

  public init(
    kind: LaunchTargetKind,
    displayName: String,
    lastKnownURL: URL,
    bookmarkData: Data? = nil
  ) {
    self.kind = kind
    self.displayName = displayName
    self.lastKnownURL = lastKnownURL
    self.bookmarkData = bookmarkData
  }
}

public struct BindingRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: BindingID
  public var physicalKeyCode: UInt16
  public var target: LaunchTarget
  public var directHotkey: HotkeyDefinition?

  public init(
    id: BindingID = .make(),
    physicalKeyCode: UInt16,
    target: LaunchTarget,
    directHotkey: HotkeyDefinition? = nil
  ) {
    self.id = id
    self.physicalKeyCode = physicalKeyCode
    self.target = target
    self.directHotkey = directHotkey
  }
}

public struct LauncherConfiguration: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 3

  public var schemaVersion: Int
  public var panelHotkey: HotkeyDefinition
  public var directModeEnabled: Bool
  public var bindings: [UInt16: BindingRecord]

  public var qBinding: LaunchTarget? {
    get { bindings[PhysicalKeyCode.q]?.target }
    set {
      if let newValue {
        let existing = bindings[PhysicalKeyCode.q]
        bindings[PhysicalKeyCode.q] = BindingRecord(
          id: existing?.id ?? .make(),
          physicalKeyCode: PhysicalKeyCode.q,
          target: newValue,
          directHotkey: existing?.directHotkey
        )
      } else {
        bindings.removeValue(forKey: PhysicalKeyCode.q)
      }
    }
  }

  public init(
    schemaVersion: Int = currentSchemaVersion,
    panelHotkey: HotkeyDefinition = .defaultPanel,
    directModeEnabled: Bool = false,
    bindings: [UInt16: BindingRecord] = [:],
    qBinding: LaunchTarget? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.panelHotkey = panelHotkey
    self.directModeEnabled = directModeEnabled
    self.bindings = bindings
    if let qBinding {
      self.bindings[PhysicalKeyCode.q] = BindingRecord(
        physicalKeyCode: PhysicalKeyCode.q,
        target: qBinding
      )
    }
  }

  public static func migratingLegacyTargets(
    panelHotkey: HotkeyDefinition = .defaultPanel,
    directModeEnabled: Bool = false,
    directModifiers: ModifierSet = .defaultDirect,
    targets: [UInt16: LaunchTarget]
  ) -> LauncherConfiguration {
    let records = Dictionary(uniqueKeysWithValues: targets.map { keyCode, target in
      (keyCode, BindingRecord(
        id: .legacy(keyCode: keyCode),
        physicalKeyCode: keyCode,
        target: target,
        directHotkey: HotkeyDefinition(keyCode: keyCode, modifiers: directModifiers)
      ))
    })
    return LauncherConfiguration(
      panelHotkey: panelHotkey,
      directModeEnabled: directModeEnabled,
      bindings: records
    )
  }

  public var targetBindings: [UInt16: LaunchTarget] { bindings.mapValues(\.target) }

  public func binding(id: BindingID) -> BindingRecord? {
    bindings.values.first { $0.id == id }
  }

  public func keyCode(for bindingID: BindingID) -> UInt16? {
    bindings.first { $0.value.id == bindingID }?.key
  }

  /// Resolves an identifier received from `LauncherRuntimeSnapshot` or another
  /// host-facing result. Projection matching intentionally has no exact-raw
  /// fallback precedence: an old raw ID is allowed to equal another record's
  /// public alias, while each record still receives a distinct public ID.
  public func binding(hostFacingID: BindingID) -> BindingRecord? {
    if let projectedMatch = bindings.values.first(where: {
      $0.id.hostSafeProjection == hostFacingID
    }) {
      return projectedMatch
    }
    return binding(id: hostFacingID)
  }

  public func keyCode(forHostFacingBindingID bindingID: BindingID) -> UInt16? {
    if let projectedMatch = bindings.first(where: {
      $0.value.id.hostSafeProjection == bindingID
    }) {
      return projectedMatch.key
    }
    return keyCode(for: bindingID)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case panelHotkey
    case directModeEnabled
    case directModifiers
    case bindings
    case qBinding
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedVersion <= Self.currentSchemaVersion else {
      throw LauncherError.unsupportedFutureSchema(decodedVersion)
    }

    panelHotkey =
      try container.decodeIfPresent(HotkeyDefinition.self, forKey: .panelHotkey)
      ?? .defaultPanel
    directModeEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .directModeEnabled)
      ?? false

    if decodedVersion >= 3 {
      if let keyedBindings = try? container.decode(
        [String: BindingRecord].self,
        forKey: .bindings
      ) {
        bindings = Dictionary(uniqueKeysWithValues: try keyedBindings.map { key, record in
          guard let keyCode = UInt16(key) else {
            throw LauncherError.invalidConfiguration("绑定槽位键无法识别")
          }
          return (keyCode, record)
        })
      } else {
        bindings =
          try container.decodeIfPresent([UInt16: BindingRecord].self, forKey: .bindings)
          ?? [:]
      }
    } else {
      let legacyModifiers =
        try container.decodeIfPresent(ModifierSet.self, forKey: .directModifiers)
        ?? .defaultDirect
      let legacyTargets: [UInt16: LaunchTarget]
      if let decodedBindings = try container.decodeIfPresent(
        [UInt16: LaunchTarget].self,
        forKey: .bindings
      ) {
        legacyTargets = decodedBindings
      } else if let legacyQBinding = try container.decodeIfPresent(
        LaunchTarget.self,
        forKey: .qBinding
      ) {
        legacyTargets = [PhysicalKeyCode.q: legacyQBinding]
      } else {
        legacyTargets = [:]
      }
      bindings = Dictionary(uniqueKeysWithValues: legacyTargets.map { keyCode, target in
        (keyCode, BindingRecord(
          id: .legacy(keyCode: keyCode),
          physicalKeyCode: keyCode,
          target: target,
          directHotkey: HotkeyDefinition(keyCode: keyCode, modifiers: legacyModifiers)
        ))
      })
    }
    schemaVersion = Self.currentSchemaVersion
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    try container.encode(panelHotkey, forKey: .panelHotkey)
    try container.encode(directModeEnabled, forKey: .directModeEnabled)
    try container.encode(
      Dictionary(uniqueKeysWithValues: bindings.map { (String($0.key), $0.value) }),
      forKey: .bindings
    )
  }
}

public struct BindingEditSession: Equatable, Sendable {
  public let id: UUID
  public let original: LauncherConfiguration
  public var draft: LauncherConfiguration
  public var dirtyKeys: Set<UInt16>

  public init(configuration: LauncherConfiguration) {
    id = UUID()
    original = configuration
    draft = configuration
    dirtyKeys = []
  }

  public var hasChanges: Bool { original != draft }

  public mutating func setTarget(_ target: LaunchTarget, at keyCode: UInt16) {
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else { return }
    if var record = draft.bindings[keyCode] {
      record.target = target
      draft.bindings[keyCode] = record
    } else {
      draft.bindings[keyCode] = BindingRecord(physicalKeyCode: keyCode, target: target)
    }
    dirtyKeys.insert(keyCode)
  }

  public mutating func setDirectHotkey(_ hotkey: HotkeyDefinition?, at keyCode: UInt16) {
    guard var record = draft.bindings[keyCode] else { return }
    record.directHotkey = hotkey
    draft.bindings[keyCode] = record
    dirtyKeys.insert(keyCode)
  }

  public mutating func removeBinding(at keyCode: UInt16) {
    draft.bindings.removeValue(forKey: keyCode)
    dirtyKeys.insert(keyCode)
  }

  public mutating func moveOrSwap(from source: UInt16, to destination: UInt16) {
    guard source != destination,
      KeySlotCatalog.allowedKeyCodes.contains(source),
      KeySlotCatalog.allowedKeyCodes.contains(destination),
      var sourceRecord = draft.bindings[source]
    else { return }

    let destinationRecord = draft.bindings[destination]
    sourceRecord.physicalKeyCode = destination
    draft.bindings[destination] = sourceRecord
    if var destinationRecord {
      destinationRecord.physicalKeyCode = source
      draft.bindings[source] = destinationRecord
    } else {
      draft.bindings.removeValue(forKey: source)
    }
    dirtyKeys.formUnion([source, destination])
  }
}

public enum ConfigurationValidator {
  public static func validate(_ configuration: LauncherConfiguration) throws {
    guard configuration.schemaVersion == LauncherConfiguration.currentSchemaVersion else {
      if configuration.schemaVersion > LauncherConfiguration.currentSchemaVersion {
        throw LauncherError.unsupportedFutureSchema(configuration.schemaVersion)
      }
      throw LauncherError.invalidConfiguration("配置版本尚未迁移")
    }
    try configuration.panelHotkey.validate()

    var bindingIDs = Set<BindingID>()
    var hostFacingBindingIDs = Set<BindingID>()
    var directHotkeys = Set<HotkeyDefinition>()
    for (slot, record) in configuration.bindings {
      guard KeySlotCatalog.allowedKeyCodes.contains(slot), record.physicalKeyCode == slot else {
        throw LauncherError.invalidConfiguration("绑定槽位无效")
      }
      guard !record.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        bindingIDs.insert(record.id).inserted
      else {
        throw LauncherError.invalidConfiguration("绑定 ID 为空或重复")
      }
      guard hostFacingBindingIDs.insert(record.id.hostSafeProjection).inserted else {
        throw LauncherError.invalidConfiguration("绑定 ID 的公开标识发生冲突")
      }
      try validate(record.target)
      if let hotkey = record.directHotkey {
        try hotkey.validate()
        guard hotkey != configuration.panelHotkey else {
          throw LauncherError.hotkeyConflict(hotkey.displayName)
        }
        guard directHotkeys.insert(hotkey).inserted else {
          throw LauncherError.hotkeyConflict(hotkey.displayName)
        }
      }
    }
  }

  private static func validate(_ target: LaunchTarget) throws {
    guard !target.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LauncherError.invalidConfiguration("目标名称不能为空")
    }
    switch target.kind {
    case .web:
      guard let scheme = target.lastKnownURL.scheme?.lowercased(),
        ["http", "https"].contains(scheme), target.lastKnownURL.host != nil
      else { throw LauncherError.unsupportedURLScheme }
    case .application, .file, .folder:
      guard target.lastKnownURL.isFileURL else {
        throw LauncherError.invalidConfiguration("文件系统目标必须是本地文件 URL")
      }
    }
  }
}

@available(*, deprecated, renamed: "LauncherConfiguration")
public typealias Stage0Configuration = LauncherConfiguration

extension HotkeyDefinition {
  public static let defaultPanel = HotkeyDefinition(
    keyCode: PhysicalKeyCode.q,
    modifiers: [.control, .option]
  )

  @available(*, deprecated, renamed: "defaultPanel")
  public static let stage0Default = defaultPanel
}

public enum PhysicalKeyCode {
  public static let q: UInt16 = 12
  public static let escape: UInt16 = 53
}

public enum TriggerSource: String, Sendable {
  case panelKeyboard
  case panelClick
  case directHotkey
}

public enum LauncherError: Error, LocalizedError, Equatable, Sendable {
  case invalidHotkey(String)
  case hotkeyConflict(String)
  case hotkeyRegistrationFailed(status: Int32)
  case hotkeyUnavailable(target: String, combination: String)
  case hotkeyRecoveryIncomplete(
    reason: String,
    failedCount: Int,
    persistenceRollbackSucceeded: Bool
  )
  case moduleAlreadyActive
  case invalidURL
  case unsupportedURLScheme
  case bookmarkCreationFailed(String)
  case bookmarkResolveFailed(String)
  case invalidConfiguration(String)
  case unsupportedFutureSchema(Int)
  case configurationReadFailed(String)
  case configurationWriteFailed(String)
  case configurationRecovered
  case importTooLarge
  case importInvalid(String)
  case targetOpenFailed(String)
  case targetUnavailable
  case noBinding

  public var errorDescription: String? {
    switch self {
    case .invalidHotkey(let message): message
    case .hotkeyConflict(let combination): "快捷键 \(combination) 已被重复使用"
    case .hotkeyRegistrationFailed: "快捷键已被系统或其他应用占用"
    case .hotkeyUnavailable(let target, let combination):
      "\(target) 的快捷键 \(combination) 已被系统或其他应用占用，请换一个组合"
    case .hotkeyRecoveryIncomplete(_, let failedCount, let persistenceRollbackSucceeded):
      if persistenceRollbackSucceeded {
        "保存失败，磁盘配置已恢复，但有 \(failedCount) 个旧快捷键未能自动恢复；请从菜单栏暂停并恢复所有快捷键"
      } else {
        "保存失败，当前会话已回到保存前状态，但磁盘配置未能回滚；请先检查存储目录权限再重新保存。另有 \(failedCount) 个快捷键可能需要暂停后恢复"
      }
    case .moduleAlreadyActive: "同一进程中已有一个快捷启动模块正在运行"
    case .invalidURL: "网址格式无效"
    case .unsupportedURLScheme: "仅支持 HTTP 或 HTTPS 网址"
    case .bookmarkCreationFailed(let message): "无法保存目标引用：\(message)"
    case .bookmarkResolveFailed(let message): "无法恢复目标引用：\(message)"
    case .invalidConfiguration(let message): "配置无效：\(message)"
    case .unsupportedFutureSchema(let version): "配置来自更新版本（schema \(version)），当前版本未作修改"
    case .configurationReadFailed(let message): "无法读取配置：\(message)"
    case .configurationWriteFailed(let message): "无法保存配置：\(message)"
    case .configurationRecovered: "主配置损坏，已从最近备份恢复"
    case .importTooLarge: "导入文件超过 5 MB 限制"
    case .importInvalid(let message): "导入文件无效：\(message)"
    case .targetOpenFailed(let message): "无法打开目标：\(message)"
    case .targetUnavailable: "目标已移动、删除或权限失效"
    case .noBinding: "该键位尚未绑定目标"
    }
  }
}
