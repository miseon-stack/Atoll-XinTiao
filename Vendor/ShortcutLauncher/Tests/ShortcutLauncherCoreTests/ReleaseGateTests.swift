import XCTest

@testable import ShortcutLauncherCore

final class ReleaseGateTests: XCTestCase {
  func testInvocationKeyMustBeReleasedBeforeGateArms() {
    var gate = ReleaseGate()

    gate.begin(invocationKeyCode: PhysicalKeyCode.q)

    XCTAssertTrue(gate.handleKeyDown(keyCode: PhysicalKeyCode.q))
    XCTAssertFalse(gate.isArmed)
    XCTAssertFalse(gate.handleKeyUp(keyCode: 13))
    XCTAssertFalse(gate.isArmed)
    XCTAssertTrue(gate.handleKeyUp(keyCode: PhysicalKeyCode.q))
    XCTAssertTrue(gate.isArmed)
  }

  func testPrimaryKeyThenModifiersMustBothBeReleased() {
    var gate = ReleaseGate()
    gate.begin(
      invocationKeyCode: PhysicalKeyCode.q,
      modifiers: [.command, .option]
    )

    XCTAssertFalse(gate.handleKeyUp(keyCode: PhysicalKeyCode.q))
    XCTAssertFalse(gate.isArmed)
    XCTAssertEqual(gate.remainingInvocationModifiers, [.command, .option])

    XCTAssertFalse(gate.handleFlagsChanged(currentModifiers: [.option]))
    XCTAssertFalse(gate.isArmed)
    XCTAssertEqual(gate.remainingInvocationModifiers, [.option])

    XCTAssertTrue(gate.handleFlagsChanged(currentModifiers: []))
    XCTAssertTrue(gate.isArmed)
    XCTAssertTrue(gate.invocationModifiers.isEmpty)
    XCTAssertTrue(gate.remainingInvocationModifiers.isEmpty)
  }

  func testModifiersCanBeReleasedBeforePrimaryKey() {
    var gate = ReleaseGate()
    gate.begin(
      invocationKeyCode: PhysicalKeyCode.q,
      modifiers: [.control, .shift]
    )

    XCTAssertFalse(gate.handleFlagsChanged(currentModifiers: []))
    XCTAssertFalse(gate.isArmed)
    XCTAssertTrue(gate.remainingInvocationModifiers.isEmpty)

    XCTAssertTrue(gate.handleKeyUp(keyCode: PhysicalKeyCode.q))
    XCTAssertTrue(gate.isArmed)
  }

  func testOnlyInvocationModifiersBlockArming() {
    var gate = ReleaseGate()
    gate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.command])

    XCTAssertFalse(gate.handleKeyUp(keyCode: PhysicalKeyCode.q))
    XCTAssertTrue(gate.handleFlagsChanged(currentModifiers: [.shift]))
    XCTAssertTrue(gate.isArmed)
  }

  func testRepeatedInvocationKeyDownIsConsumedWithoutArming() {
    var gate = ReleaseGate()
    gate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.command])

    XCTAssertTrue(gate.handleKeyDown(keyCode: PhysicalKeyCode.q))
    XCTAssertTrue(gate.handleKeyDown(keyCode: PhysicalKeyCode.q))
    XCTAssertFalse(gate.isArmed)
    XCTAssertFalse(gate.handleKeyDown(keyCode: 13))
    XCTAssertFalse(gate.isArmed)
  }

  func testRepressedPrimaryKeyMustBeReleasedAgain() {
    var gate = ReleaseGate()
    gate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.command])

    XCTAssertFalse(gate.handleKeyUp(keyCode: PhysicalKeyCode.q))
    XCTAssertTrue(gate.handleKeyDown(keyCode: PhysicalKeyCode.q))
    XCTAssertFalse(gate.handleFlagsChanged(currentModifiers: []))
    XCTAssertFalse(gate.isArmed)

    XCTAssertTrue(gate.handleKeyUp(keyCode: PhysicalKeyCode.q))
    XCTAssertTrue(gate.isArmed)
  }

  func testKeyboardSnapshotArmsWhenReleaseEventsOccurredBeforePanelMonitorStarted() {
    var gate = ReleaseGate()
    gate.begin(
      invocationKeyCode: PhysicalKeyCode.q,
      modifiers: [.command, .option]
    )

    XCTAssertTrue(gate.synchronize(
      invocationKeyIsDown: false,
      currentModifiers: []
    ))
    XCTAssertTrue(gate.isArmed)
  }

  func testKeyboardSnapshotKeepsGateWaitingWhileAnyInvocationInputIsHeld() {
    var gate = ReleaseGate()
    gate.begin(
      invocationKeyCode: PhysicalKeyCode.q,
      modifiers: [.command, .option]
    )

    XCTAssertFalse(gate.synchronize(
      invocationKeyIsDown: false,
      currentModifiers: [.option, .shift]
    ))
    XCTAssertFalse(gate.isArmed)
    XCTAssertEqual(gate.remainingInvocationModifiers, [.option])
  }

  func testManualPresentationCanArmImmediately() {
    var gate = ReleaseGate()
    gate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.command])
    gate.armImmediately()
    XCTAssertTrue(gate.isArmed)
    XCTAssertTrue(gate.invocationModifiers.isEmpty)
    XCTAssertTrue(gate.remainingInvocationModifiers.isEmpty)

    gate.reset()
    XCTAssertEqual(gate.state, .idle)
  }

  func testResetClearsPendingInvocationState() {
    var gate = ReleaseGate()
    gate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.command, .option])

    gate.reset()

    XCTAssertEqual(gate.state, .idle)
    XCTAssertTrue(gate.invocationModifiers.isEmpty)
    XCTAssertTrue(gate.remainingInvocationModifiers.isEmpty)
    XCTAssertFalse(gate.handleKeyUp(keyCode: PhysicalKeyCode.q))
    XCTAssertFalse(gate.handleFlagsChanged(currentModifiers: []))
  }
}
