import Foundation
import XCTest

@testable import ShortcutLauncherUI

@MainActor
final class LauncherUIPreferencesTests: XCTestCase {
  func testDefaultsArePrivacySafeAndIndependentFromCoreSchema() throws {
    let preferences = LauncherUIPreferences.defaults

    XCTAssertEqual(preferences.schemaVersion, 1)
    XCTAssertTrue(preferences.onlineWebsiteIconsEnabled)
    XCTAssertEqual(preferences.appearance, .system)
    XCTAssertEqual(preferences.onboardingVersion, 0)
    XCTAssertTrue(preferences.shouldShowOnboarding)

    let json = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
    XCTAssertFalse(json.contains("bindings"))
    XCTAssertFalse(json.contains("panelHotkey"))
    XCTAssertFalse(json.contains("bookmark"))
    XCTAssertFalse(json.contains("lastKnownURL"))
  }

  func testFirstLoadReturnsDefaultsWithoutCreatingAFile() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)

    let result = try await repository.load()

    XCTAssertEqual(result.preferences, .defaults)
    XCTAssertTrue(result.wasFirstRun)
    XCTAssertFalse(result.recoveredFromBackup)
    XCTAssertFalse(result.recoveredUsingDefaults)
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.preferencesURL.path))
  }

  func testRoundTripAndBackupRetainThePreviousValidSnapshot() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)
    let first = LauncherUIPreferences(
      onlineWebsiteIconsEnabled: false,
      appearance: .dark,
      onboardingVersion: 1
    )
    let second = LauncherUIPreferences(
      onlineWebsiteIconsEnabled: true,
      appearance: .light,
      onboardingVersion: 2
    )

    try await repository.save(first)
    try await repository.save(second)

    let loaded = try await repository.load()
    XCTAssertEqual(loaded.preferences, second)
    let backup = try JSONDecoder().decode(
      LauncherUIPreferences.self,
      from: Data(contentsOf: repository.backupURL)
    )
    XCTAssertEqual(backup, first)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        .contains(where: { $0.hasPrefix(".launcher-ui-preferences-tmp-") })
    )
  }

  func testCorruptPrimaryIsQuarantinedAndRecoveredFromBackup() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)
    let recoverable = LauncherUIPreferences(appearance: .dark, onboardingVersion: 1)
    let newer = LauncherUIPreferences(appearance: .light, onboardingVersion: 2)
    try await repository.save(recoverable)
    try await repository.save(newer)
    let corruptBytes = Data("not-json-and-not-a-target".utf8)
    try corruptBytes.write(to: repository.preferencesURL)

    let result = try await repository.load()

    XCTAssertEqual(result.preferences, recoverable)
    XCTAssertTrue(result.recoveredFromBackup)
    XCTAssertFalse(result.recoveredUsingDefaults)
    XCTAssertEqual(
      try JSONDecoder().decode(
        LauncherUIPreferences.self,
        from: Data(contentsOf: repository.preferencesURL)
      ),
      recoverable
    )
    let rejected = try FileManager.default.contentsOfDirectory(
      at: repository.rejectedDirectoryURL,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(rejected.count, 1)
    XCTAssertEqual(try Data(contentsOf: rejected[0]), corruptBytes)
  }

  func testCorruptPrimaryWithoutBackupRestoresDefaultsAndPreservesRejectedBytes() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let corruptBytes = Data("{not-valid-json".utf8)
    try corruptBytes.write(to: repository.preferencesURL)

    let result = try await repository.load()

    XCTAssertEqual(result.preferences, .defaults)
    XCTAssertTrue(result.recoveredUsingDefaults)
    XCTAssertFalse(result.recoveredFromBackup)
    XCTAssertEqual(
      try JSONDecoder().decode(
        LauncherUIPreferences.self,
        from: Data(contentsOf: repository.preferencesURL)
      ),
      .defaults
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        LauncherUIPreferences.self,
        from: Data(contentsOf: repository.backupURL)
      ),
      .defaults
    )
    let rejected = try FileManager.default.contentsOfDirectory(
      at: repository.rejectedDirectoryURL,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(rejected.count, 1)
    XCTAssertEqual(try Data(contentsOf: rejected[0]), corruptBytes)
  }

  func testMissingPrimaryRecoversCompatibleBackup() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)
    let expected = LauncherUIPreferences(
      onlineWebsiteIconsEnabled: false,
      appearance: .dark,
      onboardingVersion: 3
    )
    try await repository.restore(expected)
    try FileManager.default.removeItem(at: repository.preferencesURL)

    let result = try await repository.load()

    XCTAssertEqual(result.preferences, expected)
    XCTAssertTrue(result.recoveredFromBackup)
    XCTAssertTrue(FileManager.default.fileExists(atPath: repository.preferencesURL.path))
  }

  func testFutureSchemaIsRejectedWithoutOverwriteOrFallback() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let futureBytes = Data(
      "{\"schemaVersion\":99,\"onlineWebsiteIconsEnabled\":false,\"appearance\":\"dark\",\"onboardingVersion\":8}"
        .utf8
    )
    try futureBytes.write(to: repository.preferencesURL)
    try await repository.restore(.defaults)
    // Restore intentionally writes both files. Put the future document back in
    // the primary so a compatible backup exists but must not be used.
    try futureBytes.write(to: repository.preferencesURL)

    do {
      _ = try await repository.load()
      XCTFail("Expected a future schema rejection")
    } catch let error as LauncherUIPreferencesError {
      XCTAssertEqual(error, .unsupportedFutureSchema(99))
    }

    XCTAssertEqual(try Data(contentsOf: repository.preferencesURL), futureBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.rejectedDirectoryURL.path))
  }

  func testSaveRejectsInvalidCandidateAndLeavesCommittedBytesUnchanged() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)
    let committed = LauncherUIPreferences(appearance: .dark, onboardingVersion: 1)
    try await repository.save(committed)
    let committedBytes = try Data(contentsOf: repository.preferencesURL)

    do {
      try await repository.save(LauncherUIPreferences(onboardingVersion: -1))
      XCTFail("Expected invalid preferences rejection")
    } catch let error as LauncherUIPreferencesError {
      XCTAssertEqual(error, .invalidPreferences)
    }

    XCTAssertEqual(try Data(contentsOf: repository.preferencesURL), committedBytes)
  }

  func testRestoreAlignsPrimaryAndBackup() async throws {
    let fixture = try PreferencesFixture()
    defer { fixture.remove() }
    let repository = LauncherUIPreferencesRepository(storageDirectory: fixture.root)
    let expected = LauncherUIPreferences(
      onlineWebsiteIconsEnabled: false,
      appearance: .light,
      onboardingVersion: 4
    )

    try await repository.restore(expected)

    let primaryBytes = try Data(contentsOf: repository.preferencesURL)
    let backupBytes = try Data(contentsOf: repository.backupURL)
    XCTAssertEqual(primaryBytes, backupBytes)
    XCTAssertEqual(
      try JSONDecoder().decode(LauncherUIPreferences.self, from: primaryBytes),
      expected
    )
  }
}

private final class PreferencesFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LauncherUIPreferencesTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
