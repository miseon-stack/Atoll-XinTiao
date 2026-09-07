import Foundation
import XCTest

@testable import ShortcutLauncherCore

@MainActor
final class PersistenceTests: XCTestCase {
  func testConfigurationRoundTripUsesSchemaV3JSON() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = JSONConfigurationStore(storageDirectory: directory)
    let target = webTarget("example.com")
    let secondTarget = LaunchTarget(
      kind: .file,
      displayName: "notes.txt",
      lastKnownURL: URL(fileURLWithPath: "/tmp/notes.txt"),
      bookmarkData: Data("bookmark".utf8)
    )
    let expected = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [
        PhysicalKeyCode.q: BindingRecord(
          id: BindingID(rawValue: "q-binding"),
          physicalKeyCode: PhysicalKeyCode.q,
          target: target,
          directHotkey: HotkeyDefinition(keyCode: 3, modifiers: [.command, .shift])
        ),
        0: BindingRecord(physicalKeyCode: 0, target: secondTarget),
      ]
    )

    try store.save(expected)

    XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path))
    XCTAssertEqual(try store.load(), expected)
    let data = try Data(contentsOf: store.configurationURL)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["schemaVersion"] as? Int, 3)
    let bindings = try XCTUnwrap(json["bindings"] as? [String: Any])
    let qRecord = try XCTUnwrap(bindings[String(PhysicalKeyCode.q)] as? [String: Any])
    XCTAssertEqual(qRecord["id"] as? String, "q-binding")
  }

  func testLegacyV1SingleQBindingMigratesToStableRecord() throws {
    struct LegacyConfiguration: Encodable {
      let schemaVersion = 1
      let panelHotkey = HotkeyDefinition.defaultPanel
      let qBinding: LaunchTarget
    }

    let target = webTarget("example.com")
    let data = try JSONEncoder().encode(LegacyConfiguration(qBinding: target))
    let decoded = try JSONDecoder().decode(LauncherConfiguration.self, from: data)

    XCTAssertEqual(decoded.schemaVersion, 3)
    XCTAssertEqual(decoded.bindings[PhysicalKeyCode.q]?.target, target)
    XCTAssertEqual(decoded.bindings[PhysicalKeyCode.q]?.id, .legacy(keyCode: PhysicalKeyCode.q))
    XCTAssertEqual(
      decoded.bindings[PhysicalKeyCode.q]?.directHotkey,
      HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    )
    XCTAssertFalse(decoded.directModeEnabled)
  }

  func testLegacyV2ModifiersMigrateToEveryIndependentHotkey() throws {
    struct LegacyConfiguration: Encodable {
      let schemaVersion = 2
      let panelHotkey = HotkeyDefinition.defaultPanel
      let directModeEnabled = true
      let directModifiers: ModifierSet = [.command, .shift]
      let bindings: [UInt16: LaunchTarget]
    }
    let data = try JSONEncoder().encode(LegacyConfiguration(bindings: [0: webTarget("a.example"), 1: webTarget("s.example")]))
    let decoded = try JSONDecoder().decode(LauncherConfiguration.self, from: data)

    XCTAssertEqual(decoded.bindings[0]?.directHotkey, HotkeyDefinition(keyCode: 0, modifiers: [.command, .shift]))
    XCTAssertEqual(decoded.bindings[1]?.directHotkey, HotkeyDefinition(keyCode: 1, modifiers: [.command, .shift]))
    XCTAssertEqual(decoded.bindings[0]?.id, .legacy(keyCode: 0))
  }

  func testMissingConfigurationReturnsDefaults() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertEqual(try JSONConfigurationStore(storageDirectory: directory).load(), LauncherConfiguration())
  }

  func testCorruptPrimaryRecoversLastValidBackup() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigurationStore(storageDirectory: directory)
    let first = configuration(name: "first.example")
    let second = configuration(name: "second.example")
    try store.save(first)
    try store.save(second)
    try Data("not-json".utf8).write(to: store.configurationURL)

    XCTAssertEqual(try store.load(), first)
    XCTAssertTrue(store.lastLoadRecoveredFromBackup)
    XCTAssertEqual(try store.load(), first)
  }

  func testFutureSchemaIsRejectedWithoutOverwrite() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigurationStore(storageDirectory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = Data("{\"schemaVersion\":99}".utf8)
    try original.write(to: store.configurationURL)

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? LauncherError, .unsupportedFutureSchema(99))
    }
    XCTAssertEqual(try Data(contentsOf: store.configurationURL), original)
  }

  func testExportImportRoundTripAndSizeLimit() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigurationStore(storageDirectory: directory)
    let expected = configuration(name: "export.example")

    let data = try store.exportData(for: expected)
    let prepared = try store.decodeImport(data)
    XCTAssertEqual(prepared.configuration, expected)
    XCTAssertEqual(prepared.preview.bindingCount, 1)
    XCTAssertEqual(prepared.preview.webCount, 1)
    XCTAssertThrowsError(try store.decodeImport(Data(count: 5 * 1_024 * 1_024 + 1))) { error in
      XCTAssertEqual(error as? LauncherError, .importTooLarge)
    }
  }

  func testFileBookmarkResolvesAcrossResolverInstances() throws {
    let directory = temporaryDirectory()
    let fileURL = directory.appendingPathComponent("bookmark-test.txt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("stage-2".utf8).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: directory) }

    let bookmark = try FoundationBookmarkResolver().makeBookmark(for: fileURL)
    let resolved = try FoundationBookmarkResolver().resolve(bookmark)
    XCTAssertEqual(resolved.url.standardizedFileURL, fileURL.standardizedFileURL)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func webTarget(_ host: String) -> LaunchTarget {
    LaunchTarget(kind: .web, displayName: host, lastKnownURL: URL(string: "https://\(host)")!)
  }

  private func configuration(name: String) -> LauncherConfiguration {
    LauncherConfiguration(bindings: [
      0: BindingRecord(
        id: BindingID(rawValue: "stable-a"),
        physicalKeyCode: 0,
        target: webTarget(name),
        directHotkey: HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
      )
    ])
  }
}
