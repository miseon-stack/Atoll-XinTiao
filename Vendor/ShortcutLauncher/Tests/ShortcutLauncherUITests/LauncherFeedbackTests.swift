import ShortcutLauncherCore
import XCTest
@testable import ShortcutLauncherUI

final class LauncherFeedbackTests: XCTestCase {
  func testUndoTokenPreservesExactBeforeSnapshotAndRevision() {
    let configuration = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [:]
    )
    let token = LauncherUndoToken(
      before: configuration,
      expectedAfterRevision: 42,
      slotKeyCode: 12
    )

    XCTAssertEqual(token.before, configuration)
    XCTAssertEqual(token.expectedAfterRevision, 42)
    XCTAssertEqual(token.slotKeyCode, 12)
  }

  func testFeedbackCarriesOptionalUndoWithoutTargetLocation() {
    let token = LauncherUndoToken(
      before: LauncherConfiguration(),
      expectedAfterRevision: 2,
      slotKeyCode: 0
    )
    let feedback = LauncherFeedbackEvent(
      kind: .success,
      message: "已绑定到 A",
      slotKeyCode: 0,
      undoToken: token
    )

    XCTAssertEqual(feedback.kind, .success)
    XCTAssertEqual(feedback.message, "已绑定到 A")
    XCTAssertEqual(feedback.slotKeyCode, 0)
    XCTAssertEqual(feedback.undoToken, token)
  }
}
