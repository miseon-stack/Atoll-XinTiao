import Foundation
import XCTest

@testable import ShortcutLauncherCore

final class SingleBindingEditTransactionTests: XCTestCase {
  func testNewTargetRemainsPanelOnlyUntilHotkeyIsExplicitlyRecorded() throws {
    let target = LaunchTarget(
      kind: .web,
      displayName: "Example",
      lastKnownURL: try XCTUnwrap(URL(string: "https://example.com"))
    )
    var transaction = SingleBindingEditTransaction(slotKeyCode: PhysicalKeyCode.q, original: nil)

    transaction.setTarget(target)
    let candidate = transaction.merging(into: LauncherConfiguration())

    XCTAssertEqual(candidate.bindings[PhysicalKeyCode.q]?.target, target)
    XCTAssertNil(candidate.bindings[PhysicalKeyCode.q]?.directHotkey)
    XCTAssertFalse(candidate.directModeEnabled)
  }

  func testRecordedHotkeyCarriesBindingIdentityAndResumesGlobalShortcutsOnCommit() throws {
    let original = BindingRecord(
      id: BindingID(rawValue: "stable-id"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .web,
        displayName: "Old",
        lastKnownURL: try XCTUnwrap(URL(string: "https://old.example"))
      )
    )
    let hotkey = HotkeyDefinition(keyCode: 13, modifiers: [.command, .option])
    var transaction = SingleBindingEditTransaction(
      slotKeyCode: PhysicalKeyCode.q,
      original: original
    )

    transaction.setDirectHotkey(hotkey)
    let candidate = transaction.merging(into: LauncherConfiguration(
      directModeEnabled: false,
      bindings: [PhysicalKeyCode.q: original]
    ))

    XCTAssertEqual(candidate.bindings[PhysicalKeyCode.q]?.id, original.id)
    XCTAssertEqual(candidate.bindings[PhysicalKeyCode.q]?.directHotkey, hotkey)
    XCTAssertTrue(candidate.directModeEnabled)
  }

  func testCancelIsValueDiscardAndCannotMutateBaseConfiguration() throws {
    let original = BindingRecord(
      id: BindingID(rawValue: "stable-id"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .web,
        displayName: "Original",
        lastKnownURL: try XCTUnwrap(URL(string: "https://original.example"))
      )
    )
    let base = LauncherConfiguration(bindings: [0: original])
    var transaction = SingleBindingEditTransaction(slotKeyCode: 0, original: original)
    transaction.removeBinding()

    XCTAssertEqual(base.bindings[0], original)
    XCTAssertTrue(transaction.hasChanges)
  }
}
