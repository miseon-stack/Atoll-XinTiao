import Darwin
import Foundation

/// Actor-isolated, file-backed store for `LauncherUIPreferences` schema v1.
///
/// The file location is supplied by the host. Writes publish a fully encoded
/// document with a same-directory rename; a previous valid primary is retained
/// as the recovery backup. Corrupt inputs are copied to a rejected directory
/// before a compatible backup or privacy-safe defaults are restored.
public actor LauncherUIPreferencesRepository: LauncherUIPreferencesStoring {
  public nonisolated let preferencesURL: URL
  public nonisolated let backupURL: URL
  public nonisolated let rejectedDirectoryURL: URL

  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(storageDirectory: URL, fileManager: FileManager = .default) {
    preferencesURL = storageDirectory.appendingPathComponent(
      "launcher-ui-preferences.json",
      isDirectory: false
    )
    backupURL = storageDirectory.appendingPathComponent(
      "launcher-ui-preferences.backup.json",
      isDirectory: false
    )
    rejectedDirectoryURL = storageDirectory.appendingPathComponent(
      "rejected-ui-preferences",
      isDirectory: true
    )
    self.fileManager = fileManager

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
    self.decoder = JSONDecoder()
  }

  public func load() async throws -> LauncherUIPreferencesLoadResult {
    try Task.checkCancellation()
    do {
      try ensureStorageDirectory()
      guard fileManager.fileExists(atPath: preferencesURL.path) else {
        if fileManager.fileExists(atPath: backupURL.path) {
          return try recoverMissingPrimaryFromBackup()
        }
        return LauncherUIPreferencesLoadResult(
          preferences: .defaults,
          wasFirstRun: true
        )
      }

      let primaryData = try Data(contentsOf: preferencesURL)
      do {
        return LauncherUIPreferencesLoadResult(
          preferences: try decodeAndValidate(primaryData)
        )
      } catch let error as LauncherUIPreferencesError {
        if case .unsupportedFutureSchema = error { throw error }
        return try recoverCorruptPrimary()
      } catch {
        return try recoverCorruptPrimary()
      }
    } catch let error as LauncherUIPreferencesError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LauncherUIPreferencesError.readFailed
    }
  }

  public func save(_ preferences: LauncherUIPreferences) async throws {
    try Task.checkCancellation()
    do {
      let candidateData = try encodedAndValidated(preferences)
      try ensureStorageDirectory()

      if fileManager.fileExists(atPath: preferencesURL.path) {
        let existingData = try Data(contentsOf: preferencesURL)
        do {
          _ = try decodeAndValidate(existingData)
          try writeAtomically(existingData, to: backupURL)
        } catch let error as LauncherUIPreferencesError {
          if case .unsupportedFutureSchema = error { throw error }
          try quarantine(preferencesURL, reason: "invalid-primary")
        } catch {
          try quarantine(preferencesURL, reason: "invalid-primary")
        }
      }

      try writeAtomically(candidateData, to: preferencesURL)
    } catch let error as LauncherUIPreferencesError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LauncherUIPreferencesError.writeFailed
    }
  }

  public func restore(_ preferences: LauncherUIPreferences) async throws {
    do {
      let restoredData = try encodedAndValidated(preferences)
      try ensureStorageDirectory()
      try writeAtomically(restoredData, to: preferencesURL)
      try writeAtomically(restoredData, to: backupURL)
    } catch let error as LauncherUIPreferencesError {
      throw error
    } catch {
      throw LauncherUIPreferencesError.writeFailed
    }
  }

  private func recoverMissingPrimaryFromBackup() throws -> LauncherUIPreferencesLoadResult {
    let backupData = try Data(contentsOf: backupURL)
    do {
      let preferences = try decodeAndValidate(backupData)
      try writeAtomically(backupData, to: preferencesURL)
      return LauncherUIPreferencesLoadResult(
        preferences: preferences,
        recoveredFromBackup: true
      )
    } catch let error as LauncherUIPreferencesError {
      if case .unsupportedFutureSchema = error { throw error }
      try quarantine(backupURL, reason: "invalid-backup")
      return try restoreDefaultsAfterCorruption()
    } catch {
      try quarantine(backupURL, reason: "invalid-backup")
      return try restoreDefaultsAfterCorruption()
    }
  }

  private func recoverCorruptPrimary() throws -> LauncherUIPreferencesLoadResult {
    try quarantine(preferencesURL, reason: "invalid-primary")

    if fileManager.fileExists(atPath: backupURL.path) {
      let backupData = try Data(contentsOf: backupURL)
      do {
        let preferences = try decodeAndValidate(backupData)
        try writeAtomically(backupData, to: preferencesURL)
        return LauncherUIPreferencesLoadResult(
          preferences: preferences,
          recoveredFromBackup: true
        )
      } catch let error as LauncherUIPreferencesError {
        if case .unsupportedFutureSchema = error { throw error }
        try quarantine(backupURL, reason: "invalid-backup")
      } catch {
        try quarantine(backupURL, reason: "invalid-backup")
      }
    }

    return try restoreDefaultsAfterCorruption()
  }

  private func restoreDefaultsAfterCorruption() throws -> LauncherUIPreferencesLoadResult {
    let defaultData = try encodedAndValidated(.defaults)
    try writeAtomically(defaultData, to: preferencesURL)
    try writeAtomically(defaultData, to: backupURL)
    return LauncherUIPreferencesLoadResult(
      preferences: .defaults,
      recoveredUsingDefaults: true
    )
  }

  private func encodedAndValidated(_ preferences: LauncherUIPreferences) throws -> Data {
    _ = try preferences.validated()
    let data = try encoder.encode(preferences)
    _ = try decodeAndValidate(data)
    return data
  }

  private func decodeAndValidate(_ data: Data) throws -> LauncherUIPreferences {
    let decoded = try decoder.decode(LauncherUIPreferences.self, from: data)
    return try decoded.validated()
  }

  private func ensureStorageDirectory() throws {
    try fileManager.createDirectory(
      at: preferencesURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  /// Preserve the exact rejected bytes without exposing their contents through
  /// errors or generated filenames.
  private func quarantine(_ source: URL, reason: String) throws {
    guard fileManager.fileExists(atPath: source.path) else { return }
    try fileManager.createDirectory(at: rejectedDirectoryURL, withIntermediateDirectories: true)
    let destination = rejectedDirectoryURL.appendingPathComponent(
      "launcher-ui-preferences-\(reason)-\(UUID().uuidString.lowercased()).json"
    )
    try fileManager.copyItem(at: source, to: destination)
  }

  private func writeAtomically(_ data: Data, to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporaryURL = directory.appendingPathComponent(
      ".launcher-ui-preferences-tmp-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try data.write(to: temporaryURL)
    try synchronizeFile(at: temporaryURL)

    let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
    guard directoryDescriptor >= 0 else {
      throw LauncherUIPreferencesError.writeFailed
    }
    var didCloseDirectory = false
    defer {
      if !didCloseDirectory { _ = Darwin.close(directoryDescriptor) }
    }

    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    let syncResult = Darwin.fsync(directoryDescriptor)
    let closeResult = Darwin.close(directoryDescriptor)
    didCloseDirectory = true
    guard syncResult == 0, closeResult == 0 else {
      throw LauncherUIPreferencesError.writeFailed
    }
  }

  private func synchronizeFile(at url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw LauncherUIPreferencesError.writeFailed }
    let syncResult = Darwin.fsync(descriptor)
    let closeResult = Darwin.close(descriptor)
    guard syncResult == 0, closeResult == 0 else {
      throw LauncherUIPreferencesError.writeFailed
    }
  }
}
