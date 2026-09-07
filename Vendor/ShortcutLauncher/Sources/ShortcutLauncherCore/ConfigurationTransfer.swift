import Foundation

public struct ConfigurationExportEnvelope: Codable, Sendable {
  public static let currentExportVersion = 1

  public var exportVersion: Int
  public var exportedAt: Date
  public var configuration: LauncherConfiguration

  public init(
    exportVersion: Int = currentExportVersion,
    exportedAt: Date = Date(),
    configuration: LauncherConfiguration
  ) {
    self.exportVersion = exportVersion
    self.exportedAt = exportedAt
    self.configuration = configuration
  }
}

public struct ImportPreview: Equatable, Sendable {
  public var bindingCount: Int
  public var applicationCount: Int
  public var fileCount: Int
  public var folderCount: Int
  public var webCount: Int
  public var directHotkeyCount: Int

  public init(configuration: LauncherConfiguration) {
    bindingCount = configuration.bindings.count
    applicationCount = configuration.bindings.values.filter { $0.target.kind == .application }.count
    fileCount = configuration.bindings.values.filter { $0.target.kind == .file }.count
    folderCount = configuration.bindings.values.filter { $0.target.kind == .folder }.count
    webCount = configuration.bindings.values.filter { $0.target.kind == .web }.count
    directHotkeyCount = configuration.bindings.values.filter { $0.directHotkey != nil }.count
  }

  public var summary: String {
    "共 \(bindingCount) 个绑定：应用 \(applicationCount)、文件 \(fileCount)、文件夹 \(folderCount)、网页 \(webCount)；全局快捷键 \(directHotkeyCount) 个。"
  }
}

public struct PreparedConfigurationImport: Sendable {
  public var configuration: LauncherConfiguration
  public var preview: ImportPreview

  public init(configuration: LauncherConfiguration) {
    self.configuration = configuration
    preview = ImportPreview(configuration: configuration)
  }
}

extension ConfigurationStoring {
  public var backupURL: URL {
    configurationURL.deletingLastPathComponent().appendingPathComponent(
      "launcher-config.backup.json"
    )
  }

  public var lastLoadRecoveredFromBackup: Bool { false }
  public var lastLoadMigrated: Bool { false }
  public var lastLoadWasFirstRun: Bool { false }

  public func exportData(for configuration: LauncherConfiguration) throws -> Data {
    try ConfigurationValidator.validate(configuration)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(ConfigurationExportEnvelope(configuration: configuration))
  }

  public func decodeImport(_ data: Data) throws -> PreparedConfigurationImport {
    guard data.count <= 5 * 1_024 * 1_024 else { throw LauncherError.importTooLarge }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let envelope = try decoder.decode(ConfigurationExportEnvelope.self, from: data)
      guard envelope.exportVersion == ConfigurationExportEnvelope.currentExportVersion else {
        throw LauncherError.importInvalid("不支持的导出文件版本")
      }
      try ConfigurationValidator.validate(envelope.configuration)
      return PreparedConfigurationImport(configuration: envelope.configuration)
    } catch let error as LauncherError {
      throw error
    } catch {
      throw LauncherError.importInvalid("文件格式无法识别")
    }
  }
}
