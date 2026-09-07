import CoreGraphics
import XCTest

@testable import ShortcutLauncherCore

final class PanelGeometryTests: XCTestCase {
  func testCentersPreferredSizeInsideVisibleFrame() {
    let frame = PanelGeometry.frame(
      preferredSize: CGSize(width: 1080, height: 640),
      inside: CGRect(x: 0, y: 25, width: 1920, height: 1055),
      margin: 20
    )

    XCTAssertEqual(frame, CGRect(x: 420, y: 232.5, width: 1080, height: 640))
  }

  func testCentersCorrectlyOnNegativeCoordinateDisplay() {
    let frame = PanelGeometry.frame(
      preferredSize: CGSize(width: 1000, height: 600),
      inside: CGRect(x: -1600, y: -200, width: 1600, height: 900),
      margin: 24
    )

    XCTAssertEqual(frame, CGRect(x: -1300, y: -50, width: 1000, height: 600))
  }

  func testShrinksOversizedPanelToSmallVisibleFrameAndMargin() {
    let frame = PanelGeometry.frame(
      preferredSize: CGSize(width: 1080, height: 640),
      inside: CGRect(x: 100, y: 50, width: 800, height: 600),
      margin: 20
    )

    XCTAssertEqual(frame, CGRect(x: 120, y: 70, width: 760, height: 560))
  }

  func testOversizedPreferredSizeFillsVisibleFrameWithoutMargin() {
    let frame = PanelGeometry.frame(
      preferredSize: CGSize(width: 4000, height: 3000),
      inside: CGRect(x: -1920, y: 40, width: 1920, height: 1040)
    )

    XCTAssertEqual(frame, CGRect(x: -1920, y: 40, width: 1920, height: 1040))
  }

  func testMarginLargerThanHalfTheDisplayCollapsesAtCenter() {
    let frame = PanelGeometry.frame(
      preferredSize: CGSize(width: 100, height: 100),
      inside: CGRect(x: -100, y: -50, width: 200, height: 100),
      margin: 500
    )

    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 0, height: 0))
  }
}
