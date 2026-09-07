import CoreGraphics
import XCTest
@testable import ShortcutLauncherUI

final class KeyboardLayoutMetricsTests: XCTestCase {
  func testDensityThresholdsAreDeterministic() {
    XCTAssertEqual(KeyboardLayoutMetrics.resolve(availableWidth: 1_020).density, .regular)
    XCTAssertEqual(KeyboardLayoutMetrics.resolve(availableWidth: 1_019).density, .compact)
    XCTAssertEqual(KeyboardLayoutMetrics.resolve(availableWidth: 810).density, .compact)
    XCTAssertEqual(KeyboardLayoutMetrics.resolve(availableWidth: 809).density, .dense)
    XCTAssertEqual(KeyboardLayoutMetrics.resolve(availableWidth: 680).density, .dense)
    XCTAssertEqual(
      KeyboardLayoutMetrics.resolve(availableWidth: 679).density,
      .scrollingFallback
    )
  }

  func testSupportedDensitiesDoNotRequestHorizontalScrolling() {
    for width: CGFloat in [680, 810, 1_020, 1_400] {
      XCTAssertFalse(KeyboardLayoutMetrics.resolve(availableWidth: width).usesHorizontalScrolling)
    }
    XCTAssertTrue(KeyboardLayoutMetrics.resolve(availableWidth: 640).usesHorizontalScrolling)
  }

  func testContentWidthMatchesTwelveKeyRow() {
    let metrics = KeyboardLayoutMetrics.resolve(availableWidth: 1_020)
    XCTAssertEqual(
      metrics.contentWidth,
      (12 * metrics.keyWidth) + (11 * metrics.horizontalSpacing) + 8
    )
  }
}
