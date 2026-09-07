import Darwin
import Foundation
import XCTest

@testable import ShortcutLauncherCore

@MainActor
final class ConfigurationRepositoryTests: XCTestCase {
  func testRepositoryAndLegacyFacadeWriteIdenticalPrimaryAndBackupBytes() async throws {
    let facadeDirectory = temporaryDirectory()
    let repositoryDirectory = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: facadeDirectory)
      try? FileManager.default.removeItem(at: repositoryDirectory)
    }

    let facade = JSONConfigurationStore(storageDirectory: facadeDirectory)
    let repository = ConfigurationRepository(storageDirectory: repositoryDirectory)
    let first = configuration(name: "first.example", revisionKey: 3)
    let second = configuration(name: "second.example", revisionKey: 4)

    try facade.save(first)
    try facade.save(second)
    try await repository.save(first)
    try await repository.save(second)

    XCTAssertEqual(
      try Data(contentsOf: facade.configurationURL),
      try Data(contentsOf: repository.configurationURL)
    )
    XCTAssertEqual(
      try Data(contentsOf: facade.backupURL),
      try Data(contentsOf: repository.backupURL)
    )

    let facadeConfiguration = try facade.load()
    let repositoryResult = try await repository.load()
    XCTAssertEqual(repositoryResult.configuration, facadeConfiguration)
    XCTAssertFalse(repositoryResult.recoveredFromBackup)
    XCTAssertFalse(repositoryResult.migrated)
    XCTAssertFalse(repositoryResult.wasFirstRun)
  }

  func testRepositoryRestoreRemovesRejectedCandidateFromPrimaryAndBackup() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(storageDirectory: directory)
    let committed = configuration(name: "committed.example", revisionKey: 3)
    let rejectedCandidate = configuration(name: "rejected.example", revisionKey: 4)

    try await repository.save(committed)
    try await repository.save(rejectedCandidate)
    try await repository.restore(committed)

    let decoder = JSONDecoder()
    let primary = try decoder.decode(
      LauncherConfiguration.self,
      from: Data(contentsOf: repository.configurationURL)
    )
    let backup = try decoder.decode(
      LauncherConfiguration.self,
      from: Data(contentsOf: repository.backupURL)
    )
    XCTAssertEqual(primary, committed)
    XCTAssertEqual(backup, committed)
    XCTAssertFalse(
      String(decoding: try Data(contentsOf: repository.configurationURL), as: UTF8.self)
        .contains("rejected.example")
    )
    XCTAssertFalse(
      String(decoding: try Data(contentsOf: repository.backupURL), as: UTF8.self)
        .contains("rejected.example")
    )
  }

  func testLegacyFacadeRestoreAlsoRemovesRejectedCandidateFromPrimaryAndBackup() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let facade = JSONConfigurationStore(storageDirectory: directory)
    let committed = configuration(name: "committed.example", revisionKey: 3)
    let rejectedCandidate = configuration(name: "rejected.example", revisionKey: 4)

    try facade.save(committed)
    try facade.save(rejectedCandidate)
    try facade.restore(committed)

    let decoder = JSONDecoder()
    XCTAssertEqual(
      try decoder.decode(
        LauncherConfiguration.self,
        from: Data(contentsOf: facade.configurationURL)
      ),
      committed
    )
    XCTAssertEqual(
      try decoder.decode(
        LauncherConfiguration.self,
        from: Data(contentsOf: facade.backupURL)
      ),
      committed
    )
  }

  func testRepositorySurfacesTemporaryFileOpenFailureWithoutPublishingConfiguration() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operations = FaultInjectingConfigurationFileOperations(failure: .fileOpen)
    let repository = repository(
      storageDirectory: directory,
      fileOperations: operations
    )

    await assertConfigurationWriteFailure {
      try await repository.save(configuration(name: "open-failure.example", revisionKey: 3))
    }

    XCTAssertEqual(operations.calls, [.fileOpen])
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.configurationURL.path))
  }

  func testRepositorySurfacesTemporaryFileSyncFailureAndStillClosesDescriptor() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operations = FaultInjectingConfigurationFileOperations(failure: .fileSync)
    let repository = repository(
      storageDirectory: directory,
      fileOperations: operations
    )

    await assertConfigurationWriteFailure {
      try await repository.save(configuration(name: "sync-failure.example", revisionKey: 3))
    }

    XCTAssertEqual(operations.calls, [.fileOpen, .fileSync, .fileClose])
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.configurationURL.path))
  }

  func testRepositorySurfacesTemporaryFileCloseFailureWithoutPublishingConfiguration() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operations = FaultInjectingConfigurationFileOperations(failure: .fileClose)
    let repository = repository(
      storageDirectory: directory,
      fileOperations: operations
    )

    await assertConfigurationWriteFailure {
      try await repository.save(configuration(name: "close-failure.example", revisionKey: 3))
    }

    XCTAssertEqual(operations.calls, [.fileOpen, .fileSync, .fileClose])
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.configurationURL.path))
  }

  func testRepositorySurfacesParentDirectorySyncFailureAndClosesDirectoryDescriptor() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operations = FaultInjectingConfigurationFileOperations(failure: .directorySync)
    let repository = repository(
      storageDirectory: directory,
      fileOperations: operations
    )
    let candidate = configuration(name: "directory-sync-failure.example", revisionKey: 3)

    await assertConfigurationWriteFailure {
      try await repository.save(candidate)
    }

    XCTAssertEqual(
      operations.calls,
      [.fileOpen, .fileSync, .fileClose, .directoryOpen, .directorySync, .directoryClose]
    )
    // The rename has happened, but its durability is unknown when directory
    // fsync fails. The repository must report failure instead of claiming a
    // durable save; the visible file remains valid if the process continues.
    XCTAssertEqual(
      try JSONDecoder().decode(
        LauncherConfiguration.self,
        from: Data(contentsOf: repository.configurationURL)
      ),
      candidate
    )
  }

  func testRepositoryReportsFirstRunWithoutStateLeakingIntoLaterLoads() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(storageDirectory: directory)

    let first = try await repository.load()
    XCTAssertEqual(first.configuration, LauncherConfiguration())
    XCTAssertTrue(first.wasFirstRun)
    XCTAssertFalse(first.migrated)
    XCTAssertFalse(first.recoveredFromBackup)

    try await repository.save(first.configuration)
    let second = try await repository.load()
    XCTAssertFalse(second.wasFirstRun)
    XCTAssertFalse(second.migrated)
    XCTAssertFalse(second.recoveredFromBackup)

    // The first result is a value snapshot and remains valid after another load.
    XCTAssertTrue(first.wasFirstRun)
  }

  func testLegacyFacadeStillResetsLoadFlagsBeforeAThrowingLoad() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let facade = JSONConfigurationStore(storageDirectory: directory)

    _ = try facade.load()
    XCTAssertTrue(facade.lastLoadWasFirstRun)

    let futureSchema = Data("{\"schemaVersion\":99}".utf8)
    try futureSchema.write(to: facade.configurationURL)
    XCTAssertThrowsError(try facade.load())
    XCTAssertFalse(facade.lastLoadWasFirstRun)
    XCTAssertFalse(facade.lastLoadMigrated)
    XCTAssertFalse(facade.lastLoadRecoveredFromBackup)
  }

  func testRepositoryMigrationMatchesLegacyFacadeBytesAndMetadata() async throws {
    struct LegacyConfiguration: Encodable {
      let schemaVersion = 1
      let panelHotkey = HotkeyDefinition.defaultPanel
      let qBinding: LaunchTarget
    }

    let facadeDirectory = temporaryDirectory()
    let repositoryDirectory = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: facadeDirectory)
      try? FileManager.default.removeItem(at: repositoryDirectory)
    }

    let legacyData = try JSONEncoder().encode(
      LegacyConfiguration(qBinding: webTarget("legacy.example"))
    )
    try FileManager.default.createDirectory(
      at: facadeDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: repositoryDirectory,
      withIntermediateDirectories: true
    )
    try legacyData.write(
      to: facadeDirectory.appendingPathComponent("configuration-v1.json")
    )
    try legacyData.write(
      to: repositoryDirectory.appendingPathComponent("configuration-v1.json")
    )

    let facade = JSONConfigurationStore(storageDirectory: facadeDirectory)
    let repository = ConfigurationRepository(storageDirectory: repositoryDirectory)
    let facadeConfiguration = try facade.load()
    let repositoryResult = try await repository.load()

    XCTAssertEqual(repositoryResult.configuration, facadeConfiguration)
    XCTAssertTrue(facade.lastLoadMigrated)
    XCTAssertTrue(repositoryResult.migrated)
    XCTAssertFalse(repositoryResult.recoveredFromBackup)
    XCTAssertFalse(repositoryResult.wasFirstRun)
    XCTAssertEqual(
      try Data(contentsOf: facade.configurationURL),
      try Data(contentsOf: repository.configurationURL)
    )
    XCTAssertEqual(
      try Data(contentsOf: facade.backupURL),
      try Data(contentsOf: repository.backupURL)
    )
  }

  func testRepositoryRecoveryMatchesLegacyFacadeAndQuarantinesPrimary() async throws {
    let facadeDirectory = temporaryDirectory()
    let repositoryDirectory = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: facadeDirectory)
      try? FileManager.default.removeItem(at: repositoryDirectory)
    }

    let facade = JSONConfigurationStore(storageDirectory: facadeDirectory)
    let repository = ConfigurationRepository(storageDirectory: repositoryDirectory)
    let first = configuration(name: "recover.example", revisionKey: 3)
    let second = configuration(name: "corrupt.example", revisionKey: 4)
    try facade.save(first)
    try facade.save(second)
    try await repository.save(first)
    try await repository.save(second)

    let corruptData = Data("not-json".utf8)
    try corruptData.write(to: facade.configurationURL)
    try corruptData.write(to: repository.configurationURL)

    let facadeConfiguration = try facade.load()
    let repositoryResult = try await repository.load()
    XCTAssertEqual(facadeConfiguration, first)
    XCTAssertEqual(repositoryResult.configuration, first)
    XCTAssertTrue(facade.lastLoadRecoveredFromBackup)
    XCTAssertTrue(repositoryResult.recoveredFromBackup)
    XCTAssertFalse(repositoryResult.migrated)
    XCTAssertFalse(repositoryResult.wasFirstRun)

    XCTAssertEqual(try rejectedFileCount(in: facadeDirectory), 1)
    XCTAssertEqual(try rejectedFileCount(in: repositoryDirectory), 1)
    XCTAssertEqual(
      try Data(contentsOf: facade.configurationURL),
      try Data(contentsOf: repository.configurationURL)
    )
  }

  func testRepositoryRejectsFutureSchemaWithoutOverwritingOrFallingBack() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repository = ConfigurationRepository(storageDirectory: directory)
    let primary = Data("{\"schemaVersion\":99}".utf8)
    try primary.write(to: repository.configurationURL)

    do {
      _ = try await repository.load()
      XCTFail("Expected a future schema rejection")
    } catch let error as LauncherError {
      XCTAssertEqual(error, .unsupportedFutureSchema(99))
    }

    XCTAssertEqual(try Data(contentsOf: repository.configurationURL), primary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.backupURL.path))
  }

  func testRepositoryExportAndPrepareImportMatchFacadeSemantics() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let facade = JSONConfigurationStore(storageDirectory: directory)
    let repository = ConfigurationRepository(storageDirectory: temporaryDirectory())
    defer {
      try? FileManager.default.removeItem(
        at: repository.configurationURL.deletingLastPathComponent()
      )
    }
    let expected = configuration(name: "export.example", revisionKey: 3)

    let facadeData = try facade.exportData(for: expected)
    let repositoryData = try await repository.exportData(for: expected)
    let facadePrepared = try facade.decodeImport(facadeData)
    let repositoryPrepared = try await repository.prepareImport(repositoryData)
    XCTAssertEqual(repositoryPrepared.configuration, facadePrepared.configuration)
    XCTAssertEqual(repositoryPrepared.preview, facadePrepared.preview)

    do {
      _ = try await repository.prepareImport(Data(count: 5 * 1_024 * 1_024 + 1))
      XCTFail("Expected oversized import rejection")
    } catch let error as LauncherError {
      XCTAssertEqual(error, .importTooLarge)
    }
  }

  func testRepositorySerializesConcurrentBackendCalls() async throws {
    let backend = RecordingRepositoryBackend()
    let repository = ConfigurationRepository(backend: backend)
    let configurations = (0..<50).map { index in
      configuration(name: "\(index).example", revisionKey: UInt16(index % 30))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for configuration in configurations {
        group.addTask {
          try await repository.save(configuration)
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(backend.saveNames.count, 50)
    XCTAssertEqual(backend.maximumConcurrentCalls, 1)
  }

  func testRepositoryPreservesSequentialOrderAndSkipsCancelledQueuedSave() async throws {
    let backend = RecordingRepositoryBackend(blockFirstSave: true)
    let repository = ConfigurationRepository(backend: backend)
    let firstConfiguration = configuration(name: "first.example", revisionKey: 3)
    let cancelledConfiguration = configuration(name: "cancelled.example", revisionKey: 4)

    let first = Task.detached {
      try await repository.save(firstConfiguration)
    }
    XCTAssertEqual(backend.firstSaveEntered.wait(timeout: .now() + 2), .success)

    let cancelled = Task.detached {
      try await repository.save(cancelledConfiguration)
    }
    cancelled.cancel()
    backend.allowFirstSaveToFinish.signal()

    try await first.value
    do {
      try await cancelled.value
      XCTFail("Expected the queued save to observe cancellation")
    } catch is CancellationError {
      // Expected.  Cancellation is checked before beginning a file transaction.
    }

    try await repository.save(configuration(name: "last.example", revisionKey: 5))
    XCTAssertEqual(backend.saveNames, ["first.example", "last.example"])
    XCTAssertEqual(backend.maximumConcurrentCalls, 1)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "shortcut-launcher-repository-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func repository(
    storageDirectory: URL,
    fileOperations: any ConfigurationFileOperations
  ) -> ConfigurationRepository {
    ConfigurationRepository(
      backend: ConfigurationFileBackend(
        storageDirectory: storageDirectory,
        fileOperations: fileOperations
      )
    )
  }

  private func assertConfigurationWriteFailure(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected configuration write failure", file: file, line: line)
    } catch let error as LauncherError {
      guard case .configurationWriteFailed = error else {
        XCTFail("Expected configurationWriteFailed, got \(error)", file: file, line: line)
        return
      }
    } catch {
      XCTFail("Expected LauncherError, got \(error)", file: file, line: line)
    }
  }

  private func webTarget(_ host: String) -> LaunchTarget {
    LaunchTarget(
      kind: .web,
      displayName: host,
      lastKnownURL: URL(string: "https://\(host)")!
    )
  }

  private func configuration(name: String, revisionKey: UInt16) -> LauncherConfiguration {
    LauncherConfiguration(bindings: [
      0: BindingRecord(
        id: BindingID(rawValue: "repository-\(name)"),
        physicalKeyCode: 0,
        target: webTarget(name),
        directHotkey: HotkeyDefinition(
          keyCode: revisionKey,
          modifiers: [.command, .option]
        )
      )
    ])
  }

  private func rejectedFileCount(in directory: URL) throws -> Int {
    let rejected = directory.appendingPathComponent("rejected", isDirectory: true)
    return try FileManager.default.contentsOfDirectory(
      at: rejected,
      includingPropertiesForKeys: nil
    ).count
  }
}

private enum ConfigurationDurabilityOperation: Equatable, Sendable {
  case fileOpen
  case fileSync
  case fileClose
  case directoryOpen
  case directorySync
  case directoryClose
}

private final class FaultInjectingConfigurationFileOperations: ConfigurationFileOperations,
  @unchecked Sendable
{
  let failure: ConfigurationDurabilityOperation

  private let lock = NSLock()
  private var recordedCalls: [ConfigurationDurabilityOperation] = []

  init(failure: ConfigurationDurabilityOperation) {
    self.failure = failure
  }

  var calls: [ConfigurationDurabilityOperation] {
    lock.withLock { recordedCalls }
  }

  func openForSynchronization(at url: URL, isDirectory: Bool) -> Int32 {
    let operation: ConfigurationDurabilityOperation = isDirectory ? .directoryOpen : .fileOpen
    record(operation)
    guard operation != failure else { return -1 }
    return Darwin.open(url.path, O_RDONLY)
  }

  func synchronize(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32 {
    let operation: ConfigurationDurabilityOperation = isDirectory ? .directorySync : .fileSync
    record(operation)
    guard operation != failure else { return -1 }
    return Darwin.fsync(descriptor)
  }

  func close(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32 {
    let operation: ConfigurationDurabilityOperation = isDirectory ? .directoryClose : .fileClose
    record(operation)
    let result = Darwin.close(descriptor)
    return operation == failure ? -1 : result
  }

  private func record(_ operation: ConfigurationDurabilityOperation) {
    lock.withLock { recordedCalls.append(operation) }
  }
}

private final class RecordingRepositoryBackend: ConfigurationRepositoryBackend,
  @unchecked Sendable
{
  let configurationURL = URL(fileURLWithPath: "/tmp/recording-launcher-config.json")
  let backupURL = URL(fileURLWithPath: "/tmp/recording-launcher-config.backup.json")
  let firstSaveEntered = DispatchSemaphore(value: 0)
  let allowFirstSaveToFinish = DispatchSemaphore(value: 0)

  private let lock = NSLock()
  private let blockFirstSave: Bool
  private var hasBlockedFirstSave = false
  private var activeCalls = 0
  private var recordedMaximumConcurrentCalls = 0
  private var recordedSaveNames: [String] = []

  init(blockFirstSave: Bool = false) {
    self.blockFirstSave = blockFirstSave
  }

  var maximumConcurrentCalls: Int {
    lock.withLock { recordedMaximumConcurrentCalls }
  }

  var saveNames: [String] {
    lock.withLock { recordedSaveNames }
  }

  func load() throws -> ConfigurationLoadResult {
    withTrackedCall {
      ConfigurationLoadResult(configuration: LauncherConfiguration())
    }
  }

  func save(_ configuration: LauncherConfiguration) throws {
    let shouldBlock = lock.withLock { () -> Bool in
      guard blockFirstSave, !hasBlockedFirstSave else { return false }
      hasBlockedFirstSave = true
      return true
    }

    withTrackedCall {
      if shouldBlock {
        firstSaveEntered.signal()
        allowFirstSaveToFinish.wait()
      }
      let name = configuration.bindings[0]?.target.displayName ?? "missing"
      lock.withLock { recordedSaveNames.append(name) }
    }
  }

  func restore(_ configuration: LauncherConfiguration) throws {
    withTrackedCall {
      let name = configuration.bindings[0]?.target.displayName ?? "missing"
      lock.withLock { recordedSaveNames.append(name) }
    }
  }

  func exportData(for configuration: LauncherConfiguration) throws -> Data {
    try withTrackedCall { try JSONEncoder().encode(configuration) }
  }

  func prepareImport(_ data: Data) throws -> PreparedConfigurationImport {
    try withTrackedCall {
      PreparedConfigurationImport(
        configuration: try JSONDecoder().decode(LauncherConfiguration.self, from: data)
      )
    }
  }

  private func withTrackedCall<T>(_ operation: () throws -> T) rethrows -> T {
    lock.withLock {
      activeCalls += 1
      recordedMaximumConcurrentCalls = max(recordedMaximumConcurrentCalls, activeCalls)
    }
    defer { lock.withLock { activeCalls -= 1 } }
    return try operation()
  }
}
