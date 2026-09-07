import XCTest

@testable import ShortcutLauncherCore

final class HotkeyRecorderStateTests: XCTestCase {
  private let original = HotkeyDefinition(
    keyCode: PhysicalKeyCode.q,
    modifiers: [.command, .option]
  )

  func testFocusCapturesOriginalAndBeginsFocused() {
    var state = HotkeyRecorderState(value: original)

    XCTAssertEqual(
      HotkeyRecorderReducer.reduce(state: &state, event: .focus),
      .unchanged
    )

    XCTAssertEqual(state.original, original)
    XCTAssertEqual(state.selection, original)
    XCTAssertEqual(state.phase, .focused)
    XCTAssertTrue(state.isFocused)
  }

  func testFlagsChangedPreviewsOnlySupportedModifiersPassedByAdapter() {
    var state = HotkeyRecorderState(value: nil)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)

    HotkeyRecorderReducer.reduce(
      state: &state,
      event: .flagsChanged([.command, .shift])
    )

    XCTAssertEqual(state.phase, .recording(modifiers: [.command, .shift]))
  }

  func testValidCombinationBecomesCandidateAndWaitsForKeyUp() {
    var state = HotkeyRecorderState(value: nil)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)
    let candidate = HotkeyDefinition(keyCode: 13, modifiers: [.control, .option])

    let result = HotkeyRecorderReducer.reduce(
      state: &state,
      event: .keyDown(keyCode: 13, modifiers: [.control, .option], isRepeat: false)
    )

    XCTAssertEqual(result, .candidate(candidate))
    XCTAssertEqual(state.selection, candidate)
    XCTAssertEqual(state.phase, .candidate(candidate))
    XCTAssertEqual(state.pressedKeyCode, 13)
    XCTAssertTrue(state.candidateRequiresSystemValidation)

    HotkeyRecorderReducer.reduce(state: &state, event: .keyUp(keyCode: 13))
    XCTAssertNil(state.pressedKeyCode)
    XCTAssertEqual(state.phase, .candidate(candidate))

    HotkeyRecorderReducer.reduce(state: &state, event: .blur)
    XCTAssertEqual(state.phase, .idle)
    XCTAssertTrue(state.candidateRequiresSystemValidation)
  }

  func testRepeatAndSecondKeyDownInSamePressCycleAreIgnored() {
    var state = HotkeyRecorderState(value: nil)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)
    HotkeyRecorderReducer.reduce(
      state: &state,
      event: .keyDown(keyCode: 13, modifiers: [.command], isRepeat: false)
    )
    let firstCandidate = state.selection

    XCTAssertEqual(
      HotkeyRecorderReducer.reduce(
        state: &state,
        event: .keyDown(keyCode: 14, modifiers: [.command], isRepeat: true)
      ),
      .unchanged
    )
    XCTAssertEqual(
      HotkeyRecorderReducer.reduce(
        state: &state,
        event: .keyDown(keyCode: 14, modifiers: [.command], isRepeat: false)
      ),
      .unchanged
    )
    XCTAssertEqual(state.selection, firstCandidate)
  }

  func testEscRestoresValueCapturedAtFocus() {
    var state = HotkeyRecorderState(value: original)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)
    HotkeyRecorderReducer.reduce(
      state: &state,
      event: .keyDown(keyCode: 13, modifiers: [.command], isRepeat: false)
    )
    HotkeyRecorderReducer.reduce(state: &state, event: .keyUp(keyCode: 13))

    let result = HotkeyRecorderReducer.reduce(
      state: &state,
      event: .keyDown(
        keyCode: PhysicalKeyCode.escape,
        modifiers: [],
        isRepeat: false
      )
    )

    XCTAssertEqual(result, .cancelled(restored: original))
    XCTAssertEqual(state.selection, original)
    XCTAssertEqual(state.phase, .focused)
    XCTAssertFalse(state.candidateRequiresSystemValidation)
  }

  func testEscDuringSecondAttemptRestoresExistingPendingMarker() {
    var state = HotkeyRecorderState(value: nil)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)
    HotkeyRecorderReducer.reduce(
      state: &state,
      event: .keyDown(keyCode: 13, modifiers: [.command], isRepeat: false)
    )
    HotkeyRecorderReducer.reduce(state: &state, event: .keyUp(keyCode: 13))
    HotkeyRecorderReducer.reduce(state: &state, event: .blur)

    let pending = state.selection
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)
    HotkeyRecorderReducer.reduce(
      state: &state,
      event: .keyDown(keyCode: 14, modifiers: [.option], isRepeat: false)
    )
    HotkeyRecorderReducer.reduce(state: &state, event: .keyUp(keyCode: 14))
    HotkeyRecorderReducer.reduce(state: &state, event: .cancel)

    XCTAssertEqual(state.selection, pending)
    XCTAssertTrue(state.candidateRequiresSystemValidation)
  }

  func testDeleteAndForwardDeleteClearCandidate() {
    for keyCode: UInt16 in [51, 117] {
      var state = HotkeyRecorderState(value: original)
      HotkeyRecorderReducer.reduce(state: &state, event: .focus)

      XCTAssertEqual(
        HotkeyRecorderReducer.reduce(
          state: &state,
          event: .keyDown(keyCode: keyCode, modifiers: [], isRepeat: false)
        ),
        .cleared
      )
      XCTAssertNil(state.selection)
      XCTAssertEqual(state.phase, .focused)
    }
  }

  func testExplicitClearAndCancelAreIgnoredOutsideFocus() {
    var state = HotkeyRecorderState(value: original)

    XCTAssertEqual(
      HotkeyRecorderReducer.reduce(state: &state, event: .clear),
      .unchanged
    )
    XCTAssertEqual(
      HotkeyRecorderReducer.reduce(state: &state, event: .cancel),
      .unchanged
    )
    XCTAssertEqual(state.selection, original)
  }

  func testBlurStopsRecordingAndLaterKeyEventsAreIgnored() {
    var state = HotkeyRecorderState(value: original)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)
    HotkeyRecorderReducer.reduce(state: &state, event: .blur)

    XCTAssertEqual(state.phase, .idle)
    XCTAssertFalse(state.isFocused)
    XCTAssertEqual(
      HotkeyRecorderReducer.reduce(
        state: &state,
        event: .keyDown(keyCode: 13, modifiers: [.command], isRepeat: false)
      ),
      .unchanged
    )
    XCTAssertEqual(state.selection, original)
  }

  func testInvalidInputsReturnStableSpecificCodes() {
    XCTAssertEqual(
      HotkeyRecorderReducer.validationCode(keyCode: 49, modifiers: [.command]),
      .unsupportedMainKey
    )
    XCTAssertEqual(
      HotkeyRecorderReducer.validationCode(keyCode: 13, modifiers: []),
      .missingModifier
    )
    XCTAssertEqual(
      HotkeyRecorderReducer.validationCode(keyCode: 13, modifiers: [.shift]),
      .shiftOnly
    )
    XCTAssertEqual(
      HotkeyRecorderReducer.validationCode(
        keyCode: 13,
        modifiers: ModifierSet(rawValue: ModifierSet.command.rawValue | (1 << 10))
      ),
      .unsupportedModifier
    )
  }

  func testEveryCatalogKeyAcceptsEachSupportedPrimaryModifier() {
    let modifierSets: [ModifierSet] = [
      .command, .option, .control,
      [.command, .shift], [.option, .control, .shift],
    ]

    for keyCode in KeySlotCatalog.allowedKeyCodes {
      for modifiers in modifierSets {
        XCTAssertNil(
          HotkeyRecorderReducer.validationCode(keyCode: keyCode, modifiers: modifiers),
          "expected \(keyCode) with \(modifiers.rawValue) to be valid"
        )
      }
    }
  }

  func testInvalidKeyDoesNotReplaceExistingSelection() {
    var state = HotkeyRecorderState(value: original)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)

    XCTAssertEqual(
      HotkeyRecorderReducer.reduce(
        state: &state,
        event: .keyDown(keyCode: 49, modifiers: [.command], isRepeat: false)
      ),
      .rejected(.unsupportedMainKey)
    )
    XCTAssertEqual(state.selection, original)
    XCTAssertEqual(state.phase, .invalid(code: .unsupportedMainKey))
  }

  func testModifierReleaseDoesNotEraseVisibleCandidate() {
    var state = HotkeyRecorderState(value: nil)
    HotkeyRecorderReducer.reduce(state: &state, event: .focus)
    let candidate = HotkeyDefinition(keyCode: 13, modifiers: [.command])
    HotkeyRecorderReducer.reduce(
      state: &state,
      event: .keyDown(keyCode: 13, modifiers: [.command], isRepeat: false)
    )
    HotkeyRecorderReducer.reduce(state: &state, event: .keyUp(keyCode: 13))

    HotkeyRecorderReducer.reduce(state: &state, event: .flagsChanged([]))

    XCTAssertEqual(state.phase, .candidate(candidate))
  }
}
