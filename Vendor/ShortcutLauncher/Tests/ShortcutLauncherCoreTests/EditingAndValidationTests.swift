import Foundation
import XCTest

@testable import ShortcutLauncherCore

final class EditingAndValidationTests: XCTestCase {
  func testMoveToEmptySlotKeepsBindingIdentityAndHotkey() throws {
    let record = makeRecord(id: "a", slot: 0, hotkeyKey: 3)
    var session = BindingEditSession(configuration: LauncherConfiguration(bindings: [0: record]))

    session.moveOrSwap(from: 0, to: 1)

    XCTAssertNil(session.draft.bindings[0])
    XCTAssertEqual(session.draft.bindings[1]?.id.rawValue, "a")
    XCTAssertEqual(session.draft.bindings[1]?.physicalKeyCode, 1)
    XCTAssertEqual(session.draft.bindings[1]?.directHotkey?.keyCode, 3)
  }

  func testSwapMovesWholeRecords() throws {
    let a = makeRecord(id: "a", slot: 0, hotkeyKey: 3)
    let s = makeRecord(id: "s", slot: 1, hotkeyKey: 4)
    var session = BindingEditSession(configuration: LauncherConfiguration(bindings: [0: a, 1: s]))

    session.moveOrSwap(from: 0, to: 1)

    XCTAssertEqual(session.draft.bindings[0]?.id.rawValue, "s")
    XCTAssertEqual(session.draft.bindings[1]?.id.rawValue, "a")
    XCTAssertEqual(session.draft.bindings[1]?.directHotkey?.keyCode, 3)
  }

  func testValidatorRejectsDuplicateDirectShortcut() {
    let hotkey = HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    let first = BindingRecord(id: BindingID(rawValue: "a"), physicalKeyCode: 0, target: target("a"), directHotkey: hotkey)
    let second = BindingRecord(id: BindingID(rawValue: "s"), physicalKeyCode: 1, target: target("s"), directHotkey: hotkey)

    XCTAssertThrowsError(try ConfigurationValidator.validate(LauncherConfiguration(bindings: [0: first, 1: second]))) { error in
      XCTAssertEqual(error as? LauncherError, .hotkeyConflict(hotkey.displayName))
    }
  }

  func testCancelSemanticsLeaveOriginalUntouched() {
    let original = LauncherConfiguration(bindings: [0: makeRecord(id: "a", slot: 0, hotkeyKey: 3)])
    var session = BindingEditSession(configuration: original)
    session.removeBinding(at: 0)

    XCTAssertTrue(session.hasChanges)
    XCTAssertEqual(session.original, original)
    XCTAssertNotEqual(session.draft, original)
  }

  func testAll38SlotsValidateWithUniqueIndependentHotkeys() throws {
    let records = Dictionary(uniqueKeysWithValues: KeySlotCatalog.all.map { slot in
      (
        slot.keyCode,
        BindingRecord(
          id: BindingID(rawValue: "binding-\(slot.keyCode)"),
          physicalKeyCode: slot.keyCode,
          target: target("item-\(slot.keyCode)"),
          directHotkey: HotkeyDefinition(keyCode: slot.keyCode, modifiers: [.command, .shift])
        )
      )
    })
    var configuration = LauncherConfiguration(directModeEnabled: true, bindings: records)
    configuration.panelHotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: [.control, .option])

    XCTAssertNoThrow(try ConfigurationValidator.validate(configuration))
  }

  func testValidatorAcceptsLegacySchemaV3BindingIdentifiers() {
    for legacyIdentifier in [
      "中文绑定",
      "legacy binding with spaces",
      "legacy:binding:id",
      "/private-fixture/secret.txt",
      "https://private.example/path?token=secret",
      "identifier#fragment",
      String(repeating: "a", count: 129),
    ] {
      let record = BindingRecord(
        id: BindingID(rawValue: legacyIdentifier),
        physicalKeyCode: 0,
        target: target("safe")
      )

      XCTAssertNoThrow(
        try ConfigurationValidator.validate(
          LauncherConfiguration(bindings: [0: record])
        )
      )
    }
  }

  func testFiveHundredCancelledDraftsDoNotMutateOriginal() {
    let original = LauncherConfiguration(bindings: [0: makeRecord(id: "a", slot: 0, hotkeyKey: 3)])
    for _ in 0..<500 {
      var session = BindingEditSession(configuration: original)
      session.removeBinding(at: 0)
      XCTAssertEqual(session.original, original)
    }
  }

  private func makeRecord(id: String, slot: UInt16, hotkeyKey: UInt16) -> BindingRecord {
    BindingRecord(
      id: BindingID(rawValue: id),
      physicalKeyCode: slot,
      target: target(id),
      directHotkey: HotkeyDefinition(keyCode: hotkeyKey, modifiers: [.command, .option])
    )
  }

  private func target(_ name: String) -> LaunchTarget {
    LaunchTarget(kind: .web, displayName: name, lastKnownURL: URL(string: "https://\(name).example")!)
  }
}
