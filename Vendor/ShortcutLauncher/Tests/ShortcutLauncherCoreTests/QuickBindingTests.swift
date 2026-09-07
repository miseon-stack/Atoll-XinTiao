import Foundation
import XCTest

@testable import ShortcutLauncherCore

final class QuickBindingTests: XCTestCase {
  func testDefaultForNewCreatesControlSlotHotkeyWithoutResumingPausedMode() throws {
    let target = try webTarget("https://example.com", name: "Example")
    let base = LauncherConfiguration(directModeEnabled: false)

    let candidate = try QuickBindingCandidateBuilder.makeCandidate(
      from: base,
      intent: QuickBindingIntent(
        slotKeyCode: PhysicalKeyCode.q,
        target: target,
        shortcutChoice: .defaultForNew
      )
    )

    let record = try XCTUnwrap(candidate.bindings[PhysicalKeyCode.q])
    XCTAssertFalse(record.id.rawValue.isEmpty)
    XCTAssertEqual(record.physicalKeyCode, PhysicalKeyCode.q)
    XCTAssertEqual(record.target, target)
    XCTAssertEqual(
      record.directHotkey,
      HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .control)
    )
    XCTAssertFalse(candidate.directModeEnabled)
    XCTAssertEqual(candidate.schemaVersion, LauncherConfiguration.currentSchemaVersion)
  }

  func testReplacingTargetPreservesIdentityAndExistingShortcut() throws {
    let existingHotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: [.command, .shift])
    let original = BindingRecord(
      id: BindingID(rawValue: "stable-id"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: try webTarget("https://old.example", name: "Old"),
      directHotkey: existingHotkey
    )
    let unrelated = BindingRecord(
      id: BindingID(rawValue: "unrelated"),
      physicalKeyCode: 0,
      target: try webTarget("https://other.example", name: "Other"),
      directHotkey: HotkeyDefinition(keyCode: 0, modifiers: .option)
    )
    let base = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [PhysicalKeyCode.q: original, 0: unrelated]
    )
    let replacement = try webTarget("https://new.example", name: "New")

    let candidate = try QuickBindingCandidateBuilder.makeCandidate(
      from: base,
      intent: QuickBindingIntent(
        slotKeyCode: PhysicalKeyCode.q,
        target: replacement,
        shortcutChoice: .preserveExisting
      )
    )

    XCTAssertEqual(candidate.bindings[PhysicalKeyCode.q]?.id, original.id)
    XCTAssertEqual(candidate.bindings[PhysicalKeyCode.q]?.target, replacement)
    XCTAssertEqual(candidate.bindings[PhysicalKeyCode.q]?.directHotkey, existingHotkey)
    XCTAssertEqual(candidate.bindings[0], unrelated)
    XCTAssertTrue(candidate.directModeEnabled)
  }

  func testPreserveExistingOnEmptySlotProducesPanelOnlyBinding() throws {
    let candidate = try QuickBindingCandidateBuilder.makeCandidate(
      from: LauncherConfiguration(directModeEnabled: true),
      intent: QuickBindingIntent(
        slotKeyCode: 1,
        target: try webTarget("https://example.com"),
        shortcutChoice: .preserveExisting
      )
    )

    XCTAssertNil(candidate.bindings[1]?.directHotkey)
    XCTAssertTrue(candidate.directModeEnabled)
  }

  func testPanelOnlyRemovesShortcutButKeepsBindingIdentity() throws {
    let original = BindingRecord(
      id: BindingID(rawValue: "stable-id"),
      physicalKeyCode: 2,
      target: try webTarget("https://old.example"),
      directHotkey: HotkeyDefinition(keyCode: 2, modifiers: .control)
    )
    let candidate = try QuickBindingCandidateBuilder.makeCandidate(
      from: LauncherConfiguration(bindings: [2: original]),
      intent: QuickBindingIntent(
        slotKeyCode: 2,
        target: try webTarget("https://new.example"),
        shortcutChoice: .panelOnly
      )
    )

    XCTAssertEqual(candidate.bindings[2]?.id, original.id)
    XCTAssertNil(candidate.bindings[2]?.directHotkey)
  }

  func testCustomModifiersAlwaysUseSelectedSlotAsPrimaryKey() throws {
    let candidate = try QuickBindingCandidateBuilder.makeCandidate(
      from: LauncherConfiguration(),
      intent: QuickBindingIntent(
        slotKeyCode: 3,
        target: try webTarget("https://example.com"),
        shortcutChoice: .customModifiers([.control, .shift])
      )
    )

    XCTAssertEqual(
      candidate.bindings[3]?.directHotkey,
      HotkeyDefinition(keyCode: 3, modifiers: [.control, .shift])
    )
  }

  func testRejectsInvalidSlotModifiersTargetAndKnownConflict() throws {
    let target = try webTarget("https://example.com")
    XCTAssertThrowsError(try QuickBindingCandidateBuilder.makeCandidate(
      from: LauncherConfiguration(),
      intent: QuickBindingIntent(
        slotKeyCode: 65_535,
        target: target,
        shortcutChoice: .defaultForNew
      )
    ))
    XCTAssertThrowsError(try QuickBindingCandidateBuilder.makeCandidate(
      from: LauncherConfiguration(),
      intent: QuickBindingIntent(
        slotKeyCode: 3,
        target: target,
        shortcutChoice: .customModifiers([])
      )
    ))
    XCTAssertThrowsError(try QuickBindingCandidateBuilder.makeCandidate(
      from: LauncherConfiguration(),
      intent: QuickBindingIntent(
        slotKeyCode: 3,
        target: LaunchTarget(
          kind: .file,
          displayName: "Remote",
          lastKnownURL: try XCTUnwrap(URL(string: "https://example.com/file"))
        ),
        shortcutChoice: .defaultForNew
      )
    ))
    XCTAssertThrowsError(try QuickBindingCandidateBuilder.makeCandidate(
      from: LauncherConfiguration(),
      intent: QuickBindingIntent(
        slotKeyCode: PhysicalKeyCode.q,
        target: target,
        shortcutChoice: .customModifiers([.control, .option])
      )
    )) { error in
      guard case .hotkeyConflict = error as? LauncherError else {
        return XCTFail("Expected hotkeyConflict, got \(error)")
      }
    }
  }

  private func webTarget(_ value: String, name: String = "Example") throws -> LaunchTarget {
    LaunchTarget(
      kind: .web,
      displayName: name,
      lastKnownURL: try XCTUnwrap(URL(string: value))
    )
  }
}
