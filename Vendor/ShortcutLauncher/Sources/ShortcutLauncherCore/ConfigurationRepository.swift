import Darwin
import Foundation

/// The configuration together with the recovery work performed while loading it.
///
/// These values replace the stateful `lastLoad...` properties when callers use
/// the asynchronous repository API.  A result is an immutable snapshot, so a
/// later load cannot overwrite metadata that an earlier caller is inspecting.
public struct ConfigurationLoadResult: Equatable, Sendable {
  public let configuration: LauncherConfiguration
  public let recoveredFromBackup: Bool
  public let migrated: Bool
  public let wasFirstRun: Bool

  public init(
    configuration: LauncherConfiguration,
    recoveredFromBackup: Bool = false,
    migrated: Bool = false,
    wasFirstRun: Bool = false
  ) {
    self.configuration = configuration
    self.recoveredFromBackup = recoveredFromBackup
    self.migrated = migrated
    self.wasFirstRun = wasFirstRun
  }
}

/// Asynchronous persistence boundary used by the launcher module.
///
/// Implementations must serialize mutations.  In particular, a successful
/// `save` that returns before a later `load` is invoked must be visible to that
/// load.
public protocol ConfigurationRepositoryProtocol: Sendable {
  var configurationURL: URL { get }
  var backupURL: URL { get }

  func load() async throws -> ConfigurationLoadResult
  func save(_ configuration: LauncherConfiguration) async throws
  /// Restores a previously committed configuration after a later subsystem
  /// rejects an already-persisted candidate. Production repositories must avoid
  /// retaining that rejected candidate as either the primary or backup state.
  func restore(_ configuration: LauncherConfiguration) async throws
  func exportData(for configuration: LauncherConfiguration) async throws -> Data
  func prepareImport(_ data: Data) async throws -> PreparedConfigurationImport
}

extension ConfigurationRepositoryProtocol {
  /// Compatibility fallback for injected repositories. File-backed production
  /// storage overrides this to restore both primary and backup snapshots.
  public func restore(_ configuration: LauncherConfiguration) async throws {
    try await save(configuration)
  }
}

/// Actor-isolated repository.  Its synchronous backend deliberately contains
/// no suspension points: each file transaction runs to completion before the
/// actor accepts the next operation.
public actor ConfigurationRepository: ConfigurationRepositoryProtocol {
  public nonisolated let configurationURL: URL
  public nonisolated let backupURL: URL

  private let backend: any ConfigurationRepositoryBackend

  public init(storageDirectory: URL, fileManager: FileManager = .default) {
    let backend = ConfigurationFileBackend(
      storageDirectory: storageDirectory,
      fileManager: fileManager
    )
    self.backend = backend
    configurationURL = backend.configurationURL
    backupURL = backend.backupURL
  }

  /// Test seam for deterministic ordering and failure-injection coverage.
  init(backend: any ConfigurationRepositoryBackend) {
    self.backend = backend
    configurationURL = backend.configurationURL
    backupURL = backend.backupURL
  }

  public func load() async throws -> ConfigurationLoadResult {
    try Task.checkCancellation()
    return try backend.load()
  }

  public func save(_ configuration: LauncherConfiguration) async throws {
    try Task.checkCancellation()
    try backend.save(configuration)
  }

  public func restore(_ configuration: LauncherConfiguration) async throws {
    // Compensation must run even when the task that attempted the candidate
    // commit has been cancelled. Skipping this write would leave a candidate
    // that the registrar rejected as the next-launch primary configuration.
    try backend.restore(configuration)
  }

  public func exportData(for configuration: LauncherConfiguration) async throws -> Data {
    try Task.checkCancellation()
    return try backend.exportData(for: configuration)
  }

  public func prepareImport(_ data: Data) async throws -> PreparedConfigurationImport {
    try Task.checkCancellation()
    return try backend.prepareImport(data)
  }
}

/// Transitional adapter for hosts and tests that still inject the synchronous
/// `ConfigurationStoring` API.
///
/// This adapter intentionally remains MainActor-isolated. Production hosts
/// should construct `ConfigurationRepository`, while this type keeps the
/// existing initializer source-compatible during the staged migration.
@MainActor
public final class ConfigurationStoreRepositoryAdapter: ConfigurationRepositoryProtocol {
  public nonisolated let configurationURL: URL
  public nonisolated let backupURL: URL

  private let store: any ConfigurationStoring

  public init(store: any ConfigurationStoring) {
    self.store = store
    configurationURL = store.configurationURL
    backupURL = store.backupURL
  }

  public func load() async throws -> ConfigurationLoadResult {
    let configuration = try store.load()
    return ConfigurationLoadResult(
      configuration: configuration,
      recoveredFromBackup: store.lastLoadRecoveredFromBackup,
      migrated: store.lastLoadMigrated,
      wasFirstRun: store.lastLoadWasFirstRun
    )
  }

  public func save(_ configuration: LauncherConfiguration) async throws {
    try store.save(configuration)
  }

  public func restore(_ configuration: LauncherConfiguration) async throws {
    try store.restore(configuration)
  }

  public func exportData(for configuration: LauncherConfiguration) async throws -> Data {
    try store.exportData(for: configuration)
  }

  public func prepareImport(_ data: Data) async throws -> PreparedConfigurationImport {
    try store.decodeImport(data)
  }
}

/// A synchronous, nonisolated backend whose owner is responsible for
/// serialization.  Production instances are owned either by a repository actor
/// or by the legacy `@MainActor` JSON store facade.
protocol ConfigurationRepositoryBackend: Sendable {
  var configurationURL: URL { get }
  var backupURL: URL { get }

  func load() throws -> ConfigurationLoadResult
  func save(_ configuration: LauncherConfiguration) throws
  func restore(_ configuration: LauncherConfiguration) throws
  func exportData(for configuration: LauncherConfiguration) throws -> Data
  func prepareImport(_ data: Data) throws -> PreparedConfigurationImport
}

/// Small POSIX seam used to make durability failures deterministic in tests.
/// File contents and renames remain owned by `FileManager`; only the descriptor
/// operations whose return values must be checked are abstracted here.
protocol ConfigurationFileOperations: Sendable {
  func openForSynchronization(at url: URL, isDirectory: Bool) -> Int32
  func synchronize(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32
  func close(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32
}

struct DarwinConfigurationFileOperations: ConfigurationFileOperations {
  func openForSynchronization(at url: URL, isDirectory: Bool) -> Int32 {
    Darwin.open(url.path, O_RDONLY)
  }

  func synchronize(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32 {
    Darwin.fsync(descriptor)
  }

  func close(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32 {
    Darwin.close(descriptor)
  }
}

final class ConfigurationFileBackend: ConfigurationRepositoryBackend, @unchecked Sendable {
  let configurationURL: URL
  let backupURL: URL

  private let legacyConfigurationURL: URL
  private let lockURL: URL
  private let rejectedDirectoryURL: URL
  private let fileManager: FileManager
  private let fileOperations: any ConfigurationFileOperations
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    storageDirectory: URL,
    fileManager: FileManager = .default,
    fileOperations: any ConfigurationFileOperations = DarwinConfigurationFileOperations()
  ) {
    configurationURL = storageDirectory.appendingPathComponent("launcher-config.json")
    backupURL = storageDirectory.appendingPathComponent("launcher-config.backup.json")
    legacyConfigurationURL = storageDirectory.appendingPathComponent("configuration-v1.json")
    lockURL = storageDirectory.appendingPathComponent("launcher-config.lock")
    rejectedDirectoryURL = storageDirectory.appendingPathComponent("rejected", isDirectory: true)
    self.fileManager = fileManager
    self.fileOperations = fileOperations

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func load() throws -> ConfigurationLoadResult {
    try ensureDirectory()

    if fileManager.fileExists(atPath: configurationURL.path) {
      do {
        let data = try Data(contentsOf: configurationURL)
        let configuration = try decodeAndValidate(data)
        if try schemaVersion(in: data) < LauncherConfiguration.currentSchemaVersion {
          try save(configuration)
          return ConfigurationLoadResult(configuration: configuration, migrated: true)
        }
        return ConfigurationLoadResult(configuration: configuration)
      } catch let error as LauncherError {
        if case .unsupportedFutureSchema = error { throw error }
        return try recoverFromBackup(primaryError: error)
      } catch {
        return try recoverFromBackup(primaryError: error)
      }
    }

    if fileManager.fileExists(atPath: legacyConfigurationURL.path) {
      do {
        let legacyData = try Data(contentsOf: legacyConfigurationURL)
        let configuration = try decodeAndValidate(legacyData)
        try withFileLock {
          try writeAtomically(legacyData, to: backupURL)
          try writeAtomically(try encoder.encode(configuration), to: configurationURL)
        }
        return ConfigurationLoadResult(configuration: configuration, migrated: true)
      } catch let error as LauncherError {
        if case .unsupportedFutureSchema = error { throw error }
        throw LauncherError.configurationReadFailed(error.localizedDescription)
      } catch {
        throw LauncherError.configurationReadFailed(error.localizedDescription)
      }
    }

    return ConfigurationLoadResult(
      configuration: LauncherConfiguration(),
      wasFirstRun: true
    )
  }

  func save(_ configuration: LauncherConfiguration) throws {
    do {
      try ConfigurationValidator.validate(configuration)
      let candidateData = try encoder.encode(configuration)
      _ = try decodeAndValidate(candidateData)
      try ensureDirectory()

      try withFileLock {
        if fileManager.fileExists(atPath: configurationURL.path) {
          let existingData = try Data(contentsOf: configurationURL)
          _ = try decodeAndValidate(existingData)
          try writeAtomically(existingData, to: backupURL)
        }
        try writeAtomically(candidateData, to: configurationURL)
      }
    } catch let error as LauncherError {
      switch error {
      case .invalidConfiguration, .invalidHotkey, .hotkeyConflict,
        .unsupportedURLScheme, .unsupportedFutureSchema:
        throw error
      default:
        throw LauncherError.configurationWriteFailed(error.localizedDescription)
      }
    } catch {
      throw LauncherError.configurationWriteFailed(error.localizedDescription)
    }
  }

  func restore(_ configuration: LauncherConfiguration) throws {
    do {
      try ConfigurationValidator.validate(configuration)
      let restoredData = try encoder.encode(configuration)
      _ = try decodeAndValidate(restoredData)
      try ensureDirectory()

      try withFileLock {
        // Publish the previous committed state first so a process interruption
        // cannot leave the rejected candidate as the active primary. Then make
        // the recovery snapshot agree with that same committed state.
        try writeAtomically(restoredData, to: configurationURL)
        try writeAtomically(restoredData, to: backupURL)
      }
    } catch let error as LauncherError {
      switch error {
      case .invalidConfiguration, .invalidHotkey, .hotkeyConflict,
        .unsupportedURLScheme, .unsupportedFutureSchema:
        throw error
      default:
        throw LauncherError.configurationWriteFailed(error.localizedDescription)
      }
    } catch {
      throw LauncherError.configurationWriteFailed(error.localizedDescription)
    }
  }

  func exportData(for configuration: LauncherConfiguration) throws -> Data {
    try ConfigurationValidator.validate(configuration)
    let transferEncoder = JSONEncoder()
    transferEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    transferEncoder.dateEncodingStrategy = .iso8601
    return try transferEncoder.encode(
      ConfigurationExportEnvelope(configuration: configuration)
    )
  }

  func prepareImport(_ data: Data) throws -> PreparedConfigurationImport {
    guard data.count <= 5 * 1_024 * 1_024 else { throw LauncherError.importTooLarge }
    do {
      let transferDecoder = JSONDecoder()
      transferDecoder.dateDecodingStrategy = .iso8601
      let envelope = try transferDecoder.decode(ConfigurationExportEnvelope.self, from: data)
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

  private func recoverFromBackup(primaryError: Error) throws -> ConfigurationLoadResult {
    guard fileManager.fileExists(atPath: backupURL.path) else {
      throw LauncherError.configurationReadFailed(primaryError.localizedDescription)
    }

    do {
      let backupData = try Data(contentsOf: backupURL)
      let configuration = try decodeAndValidate(backupData)
      try quarantinePrimary(reason: "invalid")
      try withFileLock {
        try writeAtomically(try encoder.encode(configuration), to: configurationURL)
      }
      return ConfigurationLoadResult(
        configuration: configuration,
        recoveredFromBackup: true
      )
    } catch let error as LauncherError {
      if case .unsupportedFutureSchema = error { throw error }
      throw LauncherError.configurationReadFailed(
        "主配置和最近备份均不可用；原文件已保留"
      )
    } catch {
      throw LauncherError.configurationReadFailed(
        "主配置和最近备份均不可用；原文件已保留"
      )
    }
  }

  private func decodeAndValidate(_ data: Data) throws -> LauncherConfiguration {
    let configuration = try decoder.decode(LauncherConfiguration.self, from: data)
    try ConfigurationValidator.validate(configuration)
    return configuration
  }

  private func schemaVersion(in data: Data) throws -> Int {
    let object = try JSONSerialization.jsonObject(with: data)
    let dictionary = object as? [String: Any]
    return dictionary?["schemaVersion"] as? Int ?? 1
  }

  private func ensureDirectory() throws {
    try fileManager.createDirectory(
      at: configurationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  private func quarantinePrimary(reason: String) throws {
    guard fileManager.fileExists(atPath: configurationURL.path) else { return }
    try fileManager.createDirectory(at: rejectedDirectoryURL, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    let safeTimestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let destination = rejectedDirectoryURL.appendingPathComponent(
      "launcher-config-\(safeTimestamp)-\(reason).json"
    )
    try? fileManager.copyItem(at: configurationURL, to: destination)
  }

  private func writeAtomically(_ data: Data, to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporaryURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try data.write(to: temporaryURL)
    try synchronizeForDurability(at: temporaryURL, isDirectory: false)

    // Open the parent before publication. If the directory cannot be opened,
    // the old destination remains untouched. Keeping this descriptor open over
    // the rename also lets us durably publish the directory entry afterwards.
    let directoryDescriptor = fileOperations.openForSynchronization(
      at: directory,
      isDirectory: true
    )
    guard directoryDescriptor >= 0 else {
      throw LauncherError.configurationWriteFailed("无法打开配置目录进行同步")
    }
    var directoryDescriptorWasClosed = false
    defer {
      if !directoryDescriptorWasClosed {
        _ = fileOperations.close(
          directoryDescriptor,
          at: directory,
          isDirectory: true
        )
      }
    }

    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    let directorySyncResult = fileOperations.synchronize(
      directoryDescriptor,
      at: directory,
      isDirectory: true
    )
    let directoryCloseResult = fileOperations.close(
      directoryDescriptor,
      at: directory,
      isDirectory: true
    )
    directoryDescriptorWasClosed = true
    guard directorySyncResult == 0 else {
      throw LauncherError.configurationWriteFailed("无法同步配置目录")
    }
    guard directoryCloseResult == 0 else {
      throw LauncherError.configurationWriteFailed("无法关闭配置目录")
    }
  }

  private func synchronizeForDurability(at url: URL, isDirectory: Bool) throws {
    let descriptor = fileOperations.openForSynchronization(
      at: url,
      isDirectory: isDirectory
    )
    guard descriptor >= 0 else {
      throw LauncherError.configurationWriteFailed("无法打开配置临时文件进行同步")
    }

    // Always attempt close, including after fsync failure. Do not retry a
    // failed close: POSIX does not guarantee the descriptor still identifies
    // the same open file after close returns an error.
    let syncResult = fileOperations.synchronize(
      descriptor,
      at: url,
      isDirectory: isDirectory
    )
    let closeResult = fileOperations.close(
      descriptor,
      at: url,
      isDirectory: isDirectory
    )
    guard syncResult == 0 else {
      throw LauncherError.configurationWriteFailed("无法同步配置临时文件")
    }
    guard closeResult == 0 else {
      throw LauncherError.configurationWriteFailed("无法关闭配置临时文件")
    }
  }

  private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
    let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw LauncherError.configurationWriteFailed("无法创建配置锁")
    }
    defer { _ = Darwin.close(descriptor) }

    guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
      throw LauncherError.configurationWriteFailed("无法锁定配置文件")
    }
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
    return try operation()
  }
}
