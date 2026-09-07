import XCTest

@testable import ShortcutLauncherCore

final class DefaultDirectHotkeyPolicyTests: XCTestCase {
  func testEveryCatalogSlotMapsToControlAndTheSamePhysicalKey() throws {
    for slot in KeySlotCatalog.all {
      XCTAssertEqual(
        try DefaultDirectHotkeyPolicy.hotkey(forSlot: slot.keyCode),
        HotkeyDefinition(keyCode: slot.keyCode, modifiers: .control)
      )
    }
  }

  func testRecommendedPolicyDoesNotChangeLegacyMigrationDefault() {
    XCTAssertEqual(DefaultDirectHotkeyPolicy.recommendedModifiers, .control)
    XCTAssertEqual(ModifierSet.defaultDirect, [.command, .option])
  }

  func testCandidatesAreStableValidAndUnique() throws {
    let candidates = try DefaultDirectHotkeyPolicy.candidates(forSlot: PhysicalKeyCode.q)

    XCTAssertEqual(candidates.map(\.modifiers), [
      .control,
      .option,
      [.command, .option],
      [.control, .option],
      [.control, .shift],
    ])
    XCTAssertEqual(Set(candidates).count, candidates.count)
    XCTAssertTrue(candidates.allSatisfy { $0.keyCode == PhysicalKeyCode.q })
    for candidate in candidates {
      XCTAssertNoThrow(try candidate.validate())
    }
  }

  func testRejectsKeyOutsideCatalog() {
    XCTAssertThrowsError(try DefaultDirectHotkeyPolicy.hotkey(forSlot: 65_535)) { error in
      guard case .invalidHotkey = error as? LauncherError else {
        return XCTFail("Expected invalidHotkey, got \(error)")
      }
    }
    XCTAssertThrowsError(try DefaultDirectHotkeyPolicy.candidates(forSlot: 65_535))
  }
}
