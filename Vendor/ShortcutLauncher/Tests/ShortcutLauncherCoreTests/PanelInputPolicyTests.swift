import XCTest

@testable import ShortcutLauncherCore

final class PanelInputPolicyTests: XCTestCase {
  private let policy = PanelInputPolicy()

  func testEverySlotActivatesAfterManualPresentationIsArmed() {
    for keyCode in KeySlotCatalog.allowedKeyCodes {
      var gate = armedGate()

      XCTAssertEqual(
        policy.evaluate(
          PanelInputEvent(kind: .keyDown, keyCode: keyCode),
          ownership: .panel,
          releaseGate: &gate
        ),
        .activateSlot(keyCode),
        "expected plain key code \(keyCode) to activate its slot"
      )
    }
  }

  func testSupportedModifierMatrixNeverActivatesASlot() {
    let modifierSets: [ModifierSet] = [
      .control,
      .option,
      .command,
      .shift,
      [.control, .option],
      [.command, .shift],
      [.control, .option, .command, .shift],
    ]

    for keyCode in KeySlotCatalog.allowedKeyCodes {
      for modifiers in modifierSets {
        var gate = armedGate()
        XCTAssertEqual(
          policy.evaluate(
            PanelInputEvent(
              kind: .keyDown,
              keyCode: keyCode,
              modifiers: modifiers
            ),
            ownership: .panel,
            releaseGate: &gate
          ),
          .passThrough,
          "expected \(keyCode) + modifier bits \(modifiers.rawValue) to pass through"
        )
      }
    }
  }

  func testUnsupportedKeyboardStateBitsDoNotDisablePlainSlotInput() {
    let capsLockLikeState = ModifierSet(rawValue: 1 << 20)
    var gate = armedGate()

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(
          kind: .keyDown,
          keyCode: PhysicalKeyCode.q,
          modifiers: capsLockLikeState
        ),
        ownership: .panel,
        releaseGate: &gate
      ),
      .activateSlot(PhysicalKeyCode.q)
    )
  }

  func testEveryChildInputOwnerReceivesEventsWithoutMutatingReleaseGate() {
    for ownership in PanelInputOwnership.allCases where ownership != .panel {
      var gate = ReleaseGate()
      gate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.control, .option])
      let original = gate

      XCTAssertEqual(
        policy.evaluate(
          PanelInputEvent(
            kind: .keyUp,
            keyCode: PhysicalKeyCode.q,
            modifiers: [.control, .option]
          ),
          ownership: ownership,
          releaseGate: &gate
        ),
        .passThrough,
        "expected \(ownership.rawValue) to own its key events"
      )
      XCTAssertEqual(gate, original)
    }
  }

  func testReleaseGateConsumesOnlyInvocationSequenceThenAllowsSlots() {
    var gate = ReleaseGate()
    gate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.control, .option])

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(
          kind: .keyDown,
          keyCode: PhysicalKeyCode.q,
          modifiers: [.control, .option],
          isRepeat: true
        ),
        ownership: .panel,
        releaseGate: &gate
      ),
      .consume
    )
    XCTAssertFalse(gate.isArmed)

    // An unrelated slot cannot activate before the invocation chord is released,
    // but AppKit is still allowed to route the event elsewhere.
    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .keyDown, keyCode: 13),
        ownership: .panel,
        releaseGate: &gate
      ),
      .passThrough
    )

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(
          kind: .keyUp,
          keyCode: PhysicalKeyCode.q,
          modifiers: [.control, .option]
        ),
        ownership: .panel,
        releaseGate: &gate
      ),
      .consume
    )
    XCTAssertFalse(gate.isArmed)

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(
          kind: .flagsChanged,
          keyCode: 0,
          modifiers: [.option]
        ),
        ownership: .panel,
        releaseGate: &gate
      ),
      .consume
    )
    XCTAssertFalse(gate.isArmed)

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .flagsChanged, keyCode: 0),
        ownership: .panel,
        releaseGate: &gate
      ),
      .consume
    )
    XCTAssertTrue(gate.isArmed)

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .keyDown, keyCode: 13),
        ownership: .panel,
        releaseGate: &gate
      ),
      .activateSlot(13)
    )
  }

  func testReleaseGateLeavesUnrelatedKeyUpAndArmedFlagsEventsUntouched() {
    var waitingGate = ReleaseGate()
    waitingGate.begin(invocationKeyCode: PhysicalKeyCode.q, modifiers: [.control])
    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .keyUp, keyCode: 13),
        ownership: .panel,
        releaseGate: &waitingGate
      ),
      .passThrough
    )
    XCTAssertFalse(waitingGate.isArmed)

    var armedGate = armedGate()
    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .flagsChanged, keyCode: 0, modifiers: [.shift]),
        ownership: .panel,
        releaseGate: &armedGate
      ),
      .passThrough
    )
  }

  func testRepeatIsConsumedWithoutActivatingAndUnknownKeyPassesThrough() {
    var gate = armedGate()
    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(
          kind: .keyDown,
          keyCode: PhysicalKeyCode.q,
          isRepeat: true
        ),
        ownership: .panel,
        releaseGate: &gate
      ),
      .consume
    )

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .keyDown, keyCode: 49, isRepeat: true),
        ownership: .panel,
        releaseGate: &gate
      ),
      .passThrough
    )
  }

  func testOnlyPlainNonRepeatedEscapeDismissesThePanel() {
    var gate = armedGate()
    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .keyDown, keyCode: PhysicalKeyCode.escape),
        ownership: .panel,
        releaseGate: &gate
      ),
      .dismissPanel
    )

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(
          kind: .keyDown,
          keyCode: PhysicalKeyCode.escape,
          modifiers: [.command]
        ),
        ownership: .panel,
        releaseGate: &gate
      ),
      .passThrough
    )

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(
          kind: .keyDown,
          keyCode: PhysicalKeyCode.escape,
          isRepeat: true
        ),
        ownership: .panel,
        releaseGate: &gate
      ),
      .consume
    )
  }

  func testIdleGateCannotActivateOrDismiss() {
    var gate = ReleaseGate()

    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .keyDown, keyCode: PhysicalKeyCode.q),
        ownership: .panel,
        releaseGate: &gate
      ),
      .passThrough
    )
    XCTAssertEqual(
      policy.evaluate(
        PanelInputEvent(kind: .keyDown, keyCode: PhysicalKeyCode.escape),
        ownership: .panel,
        releaseGate: &gate
      ),
      .passThrough
    )
  }

  private func armedGate() -> ReleaseGate {
    var gate = ReleaseGate()
    gate.armImmediately()
    return gate
  }
}
