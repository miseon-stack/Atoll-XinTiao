import XCTest

@testable import ShortcutLauncherCore

@MainActor
final class HotkeyLifecycleTests: XCTestCase {
  func testStartStopStartDoesNotDuplicateRegistration() async throws {
    let registrar = FakeHotkeyRegistrar()
    let lifecycle = HotkeyLifecycle(registrar: registrar)

    try await lifecycle.start(panelHotkey: .defaultPanel) { _ in }
    try await lifecycle.start(panelHotkey: .defaultPanel) { _ in }

    XCTAssertEqual(registrar.registerCount, 1)
    XCTAssertEqual(lifecycle.state, .started)

    await lifecycle.stop()
    await lifecycle.stop()

    XCTAssertEqual(registrar.unregisterAllCount, 1)
    XCTAssertEqual(registrar.shutdownCount, 1)
    XCTAssertEqual(lifecycle.state, .stopped)

    try await lifecycle.start(panelHotkey: .defaultPanel) { _ in }
    XCTAssertEqual(registrar.registerCount, 2)
  }

  func testFailedStartShutsDownRegistrarAndCanRetry() async throws {
    let registrar = FakeHotkeyRegistrar()
    registrar.nextRegisterError = FakeFailure.registration
    let lifecycle = HotkeyLifecycle(registrar: registrar)

    do {
      try await lifecycle.start(panelHotkey: .defaultPanel) { _ in }
      XCTFail("Expected the first registration to fail")
    } catch FakeFailure.registration {
      // Expected.
    }

    XCTAssertEqual(lifecycle.state, .stopped)
    XCTAssertEqual(registrar.shutdownCount, 1)
    XCTAssertEqual(registrar.unregisterAllCount, 1)

    try await lifecycle.start(panelHotkey: .defaultPanel) { _ in }
    XCTAssertEqual(lifecycle.state, .started)
    XCTAssertEqual(registrar.registerCount, 2)
  }
}

private enum FakeFailure: Error {
  case registration
}

@MainActor
private final class FakeHotkeyRegistrar: HotkeyRegistering {
  var registerCount = 0
  var unregisterAllCount = 0
  var shutdownCount = 0
  var nextRegisterError: Error?
  var handler: (@MainActor @Sendable (HotkeyID) -> Void)?

  func setHandler(_ handler: @escaping @MainActor @Sendable (HotkeyID) -> Void) {
    self.handler = handler
  }

  func register(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    registerCount += 1
    if let nextRegisterError {
      self.nextRegisterError = nil
      throw nextRegisterError
    }
  }

  func replace(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {}

  func unregister(id: HotkeyID) async {}

  func unregisterAll() async {
    unregisterAllCount += 1
  }

  func shutdown() async {
    shutdownCount += 1
    await unregisterAll()
  }
}
