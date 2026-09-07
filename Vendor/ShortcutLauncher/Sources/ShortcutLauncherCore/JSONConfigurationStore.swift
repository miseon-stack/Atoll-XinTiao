import Foundation

@MainActor
public final class JSONConfigurationStore: ConfigurationStoring {
  public let configurationURL: URL
  public let backupURL: URL
  public private(set) var lastLoadRecoveredFromBackup = false
  public private(set) var lastLoadMigrated = false
  public private(set) var lastLoadWasFirstRun = false

  private let backend: ConfigurationFileBackend

  public init(storageDirectory: URL, fileManager: FileManager = .default) {
    let backend = ConfigurationFileBackend(
      storageDirectory: storageDirectory,
      fileManager: fileManager
    )
    self.backend = backend
    configurationURL = backend.configurationURL
    backupURL = backend.backupURL
  }

  public func load() throws -> LauncherConfiguration {
    lastLoadRecoveredFromBackup = false
    lastLoadMigrated = false
    lastLoadWasFirstRun = false
    let result = try backend.load()
    lastLoadRecoveredFromBackup = result.recoveredFromBackup
    lastLoadMigrated = result.migrated
    lastLoadWasFirstRun = result.wasFirstRun
    return result.configuration
  }

  public func save(_ configuration: LauncherConfiguration) throws {
    try backend.save(configuration)
  }

  public func restore(_ configuration: LauncherConfiguration) throws {
    try backend.restore(configuration)
  }

  public func exportData(for configuration: LauncherConfiguration) throws -> Data {
    try backend.exportData(for: configuration)
  }

  public func decodeImport(_ data: Data) throws -> PreparedConfigurationImport {
    try backend.prepareImport(data)
  }
}
