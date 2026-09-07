import AppKit
import XCTest

@testable import ShortcutLauncherCore
@testable import ShortcutLauncherUI

@MainActor
final class HotkeyRecorderViewTests: XCTestCase {
  func testModifierConversionIncludesOnlyFourSupportedFlags() {
    let flags: NSEvent.ModifierFlags = [
      .command, .option, .control, .shift, .capsLock, .function, .numericPad,
    ]

    XCTAssertEqual(
      LocalHotkeyRecorderNSView.modifierSet(from: flags),
      [.command, .option, .control, .shift]
    )
  }

  func testComponentPublishesCandidateClearAndCancelToOwner() {
    let original = HotkeyDefinition(keyCode: 12, modifiers: [.control, .option])
    let candidate = HotkeyDefinition(keyCode: 13, modifiers: [.command, .shift])
    let view = LocalHotkeyRecorderNSView(hotkey: original)
    var values: [HotkeyDefinition?] = []
    view.onValueChange = { values.append($0) }

    view.process(.focus)
    view.process(
      .keyDown(keyCode: candidate.keyCode, modifiers: candidate.modifiers, isRepeat: false)
    )
    view.process(.keyUp(keyCode: candidate.keyCode))
    view.process(.clear)
    view.process(.cancel)

    XCTAssertEqual(values.count, 3)
    XCTAssertEqual(values[0], candidate)
    XCTAssertNil(values[1])
    XCTAssertEqual(values[2], original)
  }

  func testComponentDoesNotPublishRejectedOrRepeatedInput() {
    let view = LocalHotkeyRecorderNSView(hotkey: nil)
    var publicationCount = 0
    view.onValueChange = { _ in publicationCount += 1 }

    view.process(.focus)
    XCTAssertEqual(
      view.process(
        .keyDown(keyCode: 49, modifiers: [.command], isRepeat: false)
      ),
      .rejected(.unsupportedMainKey)
    )
    view.process(.keyUp(keyCode: 49))
    view.process(.keyDown(keyCode: 13, modifiers: [.command], isRepeat: true))

    XCTAssertEqual(publicationCount, 0)
  }

  func testExternalUpdateDoesNotClobberFocusedRecording() {
    let original = HotkeyDefinition(keyCode: 12, modifiers: [.control, .option])
    let external = HotkeyDefinition(keyCode: 14, modifiers: [.command])
    let view = LocalHotkeyRecorderNSView(hotkey: original)

    view.process(.focus)
    view.updateExternalHotkey(external)
    XCTAssertEqual(view.recorderState.selection, original)

    view.process(.blur)
    view.updateExternalHotkey(external)
    XCTAssertEqual(view.recorderState.selection, external)
  }

  func testCommandKeyEquivalentIsConsumedAndRecordedOnlyWhileFirstResponder() throws {
    let view = LocalHotkeyRecorderNSView(hotkey: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    XCTAssertTrue(window.makeFirstResponder(view))

    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .option],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "q",
        charactersIgnoringModifiers: "q",
        isARepeat: false,
        keyCode: 12
      )
    )

    XCTAssertTrue(view.performKeyEquivalent(with: event))
    XCTAssertEqual(
      view.recorderState.selection,
      HotkeyDefinition(keyCode: 12, modifiers: [.command, .option])
    )
  }

  func testAsyncActivationFinishesBeforeFirstResponderAndCandidateDeactivates() async throws {
    let activation = RecorderActivationProbe(startsReady: false)
    let view = LocalHotkeyRecorderNSView(hotkey: nil)
    view.onActivationRequest = { await activation.activate() }
    view.onDeactivation = { activation.deactivate() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = view

    _ = window.makeFirstResponder(view)
    XCTAssertFalse(view.recorderState.isFocused)
    for _ in 0..<20 where activation.activationCount == 0 { await Task.yield() }
    XCTAssertEqual(activation.activationCount, 1)
    XCTAssertFalse(window.firstResponder === view)

    activation.resumeActivation()
    for _ in 0..<20 where window.firstResponder !== view { await Task.yield() }
    XCTAssertTrue(window.firstResponder === view)
    XCTAssertTrue(view.recorderState.isFocused)

    let candidate = HotkeyDefinition(keyCode: 12, modifiers: [.command, .option])
    XCTAssertEqual(
      view.process(
        .keyDown(
          keyCode: candidate.keyCode,
          modifiers: candidate.modifiers,
          isRepeat: false
        )
      ),
      .candidate(candidate)
    )
    for _ in 0..<20 where activation.deactivationCount == 0 { await Task.yield() }

    XCTAssertFalse(window.firstResponder === view)
    XCTAssertFalse(view.recorderState.isFocused)
    XCTAssertEqual(activation.deactivationCount, 1)
    XCTAssertEqual(view.accessibilityValue() as? String, "⌥⌘Q · 待系统验证")
  }

  func testPresentingRecorderWithoutFocusDoesNotRequestGlobalIsolation() async {
    let activation = RecorderActivationProbe(startsReady: true)
    let view = LocalHotkeyRecorderNSView(hotkey: nil)
    view.onActivationRequest = { await activation.activate() }
    view.onDeactivation = { activation.deactivate() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = view

    await Task.yield()

    XCTAssertFalse(window.firstResponder === view)
    XCTAssertFalse(view.recorderState.isFocused)
    XCTAssertEqual(activation.activationCount, 0)
    XCTAssertEqual(activation.deactivationCount, 0)
  }

  func testClearCancelBlurDeactivateButInvalidInputKeepsCaptureActive() async {
    let activation = RecorderActivationProbe(startsReady: true)
    let view = LocalHotkeyRecorderNSView(
      hotkey: HotkeyDefinition(keyCode: 12, modifiers: [.command])
    )
    view.onActivationRequest = { await activation.activate() }
    view.onDeactivation = { activation.deactivate() }
    let otherResponder = NSTextField(string: "")
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
    content.addSubview(view)
    content.addSubview(otherResponder)
    let window = NSWindow(
      contentRect: content.frame,
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = content

    func activate() async {
      _ = window.makeFirstResponder(view)
      for _ in 0..<20 where window.firstResponder !== view { await Task.yield() }
    }

    await activate()
    XCTAssertEqual(
      view.process(.keyDown(keyCode: 49, modifiers: [.command], isRepeat: false)),
      .rejected(.unsupportedMainKey)
    )
    XCTAssertTrue(window.firstResponder === view)
    XCTAssertEqual(activation.deactivationCount, 0)
    view.process(.keyUp(keyCode: 49))
    XCTAssertEqual(view.process(.clear), .cleared)
    for _ in 0..<20 where activation.deactivationCount < 1 { await Task.yield() }

    await activate()
    XCTAssertEqual(view.process(.cancel), .cancelled(restored: nil))
    for _ in 0..<20 where activation.deactivationCount < 2 { await Task.yield() }

    await activate()
    XCTAssertTrue(window.makeFirstResponder(otherResponder))
    for _ in 0..<20 where activation.deactivationCount < 3 { await Task.yield() }

    XCTAssertEqual(activation.activationCount, 3)
    XCTAssertEqual(activation.deactivationCount, 3)
    XCTAssertFalse(view.recorderState.isFocused)
  }

  func testInjectedLabelProviderMergesFallbacksAndPublishesRevision() {
    var loadCount = 0
    let provider = SystemKeyLabelProvider(observesInputSourceChanges: false) {
      loadCount += 1
      return [12: "a", 13: ""]
    }

    XCTAssertEqual(loadCount, 1)
    XCTAssertEqual(provider.snapshot.revision, 1)
    XCTAssertEqual(provider.snapshot.label(for: 12), "a")
    XCTAssertEqual(provider.snapshot.label(for: 13), "W")
    XCTAssertEqual(provider.snapshot.labels.count, 38)

    provider.refresh()
    XCTAssertEqual(loadCount, 2)
    XCTAssertEqual(provider.snapshot.revision, 2)
  }

  func testSystemLabelProviderObservesOnlyInsideExplicitLifecycle() {
    var loadCount = 0
    let provider = SystemKeyLabelProvider(observesInputSourceChanges: true) {
      loadCount += 1
      return [12: "a"]
    }

    XCTAssertEqual(loadCount, 1)
    provider.simulateInputSourceChangeForTesting()
    XCTAssertEqual(loadCount, 1)

    provider.startObserving()
    provider.startObserving()
    provider.simulateInputSourceChangeForTesting()
    XCTAssertEqual(loadCount, 2)

    provider.stopObserving()
    provider.simulateInputSourceChangeForTesting()
    XCTAssertEqual(loadCount, 2)

    provider.startObserving()
    provider.simulateInputSourceChangeForTesting()
    XCTAssertEqual(loadCount, 3)
    provider.stopObserving()
  }

  func testSystemLabelProviderAlwaysProducesCompleteSafeSnapshot() {
    let provider = SystemKeyLabelProvider(observesInputSourceChanges: false)

    XCTAssertEqual(provider.snapshot.labels.count, 38)
    for slot in KeySlotCatalog.all {
      XCTAssertFalse(provider.snapshot.label(for: slot.keyCode).isEmpty)
    }
  }

  func testSnapshotFormatsLayoutLabelWithoutChangingPhysicalKeyCode() {
    let snapshot = KeyLabelSnapshot(revision: 7, labels: [12: "A"])
    let hotkey = HotkeyDefinition(keyCode: 12, modifiers: [.command, .option])

    XCTAssertEqual(snapshot.displayName(for: hotkey), "⌥⌘A")
    XCTAssertEqual(hotkey.keyCode, 12)
    XCTAssertEqual(snapshot.revision, 7)
  }
}

@MainActor
private final class RecorderActivationProbe {
  private var isReady: Bool
  private var continuation: CheckedContinuation<Bool, Never>?
  private(set) var activationCount = 0
  private(set) var deactivationCount = 0

  init(startsReady: Bool) {
    isReady = startsReady
  }

  func activate() async -> Bool {
    activationCount += 1
    if isReady { return true }
    return await withCheckedContinuation { continuation = $0 }
  }

  func resumeActivation() {
    isReady = true
    continuation?.resume(returning: true)
    continuation = nil
  }

  func deactivate() {
    deactivationCount += 1
  }
}
