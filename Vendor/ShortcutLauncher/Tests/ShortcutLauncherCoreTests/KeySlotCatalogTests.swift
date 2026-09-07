import XCTest

@testable import ShortcutLauncherCore

final class KeySlotCatalogTests: XCTestCase {
  func testCatalogContainsTheExpected38UniquePhysicalKeys() {
    XCTAssertEqual(KeySlotCatalog.rows.map(\.count), [12, 10, 9, 7])
    XCTAssertEqual(KeySlotCatalog.all.count, 38)
    XCTAssertEqual(Set(KeySlotCatalog.all.map(\.keyCode)).count, 38)
    XCTAssertEqual(KeySlotCatalog.allowedKeyCodes.count, 38)
  }

  func testCatalogUsesMacVirtualKeyCodesInsteadOfCharacters() {
    XCTAssertEqual(KeySlotCatalog.definition(for: 12)?.fallbackLabel, "Q")
    XCTAssertEqual(KeySlotCatalog.definition(for: 0)?.fallbackLabel, "A")
    XCTAssertEqual(KeySlotCatalog.definition(for: 46)?.fallbackLabel, "M")
  }
}
