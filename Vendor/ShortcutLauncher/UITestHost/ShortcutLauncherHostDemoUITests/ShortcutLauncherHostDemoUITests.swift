import XCTest

final class ShortcutLauncherHostDemoUITests: XCTestCase {
  private let qKeyCode: UInt16 = 12
  private var app: XCUIApplication!
  private var storageDirectory: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    guard
      let temporaryRootPath = ProcessInfo.processInfo.environment[
        "SHORTCUT_LAUNCHER_UI_TEST_TEMP_ROOT"
      ], !temporaryRootPath.isEmpty
    else {
      throw XCTSkip(
        "Run through scripts/verify-phase4.sh with RUN_PHASE4_UI_TESTS=1 so every UI-test artifact stays in a disposable /private/tmp tree."
      )
    }
    let temporaryRoot = URL(fileURLWithPath: temporaryRootPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    XCTAssertTrue(
      temporaryRoot.path.hasPrefix("/private/tmp/shortcut-launcher-phase4."),
      "The UI-test runtime root must be the isolated directory created by verify-phase4.sh."
    )
    storageDirectory =
      temporaryRoot
      .appendingPathComponent("shortcut-launcher-ui-\(UUID().uuidString)", isDirectory: true)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: storageDirectory.path),
      "The host deliberately accepts only a new temporary directory in UI-test mode."
    )
  }

  override func tearDownWithError() throws {
    if testRun?.failureCount ?? 0 > 0, let app, app.state != .notRunning,
      launcherWindow.exists
    {
      let attachment = XCTAttachment(screenshot: launcherWindow.screenshot())
      attachment.name = "脱敏 UI fixture 失败现场"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    app?.terminate()
    if let storageDirectory {
      try? FileManager.default.removeItem(at: storageDirectory)
    }
    app = nil
    storageDirectory = nil
  }

  func testEmptyConfigurationShowsGridAndQuickBindsChosenNonQSlot() throws {
    launch(fixture: "empty")

    assertGridVisibleWithoutQuickBinding(slotKeyCode: 0)
    openQuickBinding(keyCode: 0)
    bindWebURL("quick-a.example")

    let aState = identified("launcher.slot.0")
    XCTAssertTrue(waitUntilText(aState, contains: "quick-a.example"))
    XCTAssertTrue(waitUntilText(aState, contains: "⌃A"))
    XCTAssertTrue(waitUntilText(identified("launcher.slot.12"), contains: "未绑定"))
    XCTAssertFalse(identified("launcher.quick.popover").exists)
  }

  func testCancellingUserChosenNonQSlotDoesNotSaveOrReopenQuickBinding() throws {
    launch(fixture: "empty")

    assertGridVisibleWithoutQuickBinding(slotKeyCode: 0)
    openQuickBinding(keyCode: 0)
    let popover = identified("launcher.quick.popover")
    click(identified("launcher.quick.kind.网址"))
    let field = identified("launcher.quick.web.input")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    click(field)
    field.typeText("cancelled-a.example")
    click(identified("launcher.quick.close"))

    XCTAssertTrue(waitForNonexistence(popover))
    let aState = identified("launcher.slot.0")
    let qState = identified("launcher.slot.12")
    XCTAssertTrue(aState.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilText(aState, contains: "未绑定"))
    XCTAssertTrue(qState.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilText(qState, contains: "未绑定"))
    XCTAssertFalse(popover.exists)
  }

  func testDefaultSlotShortcutIsSavedWithoutOpeningRecorder() throws {
    launch(fixture: "empty")

    assertGridVisibleWithoutQuickBinding(slotKeyCode: qKeyCode)
    openQuickBinding(keyCode: qKeyCode)
    XCTAssertFalse(identified("launcher.hotkey.recorder").exists)
    bindWebURL("direct.example")

    let qState = identified("launcher.slot.12")
    XCTAssertTrue(waitUntilText(qState, contains: "direct.example"))
    XCTAssertTrue(waitUntilText(qState, contains: "⌃Q"))
    XCTAssertFalse(identified("launcher.quick.popover").exists)
  }

  func testOpeningExistingBindingQuickSurfaceDoesNotModifyUntilTargetConfirmation() throws {
    launch(fixture: "one-panel-only")

    openExistingQuickBinding(keyCode: qKeyCode)
    XCTAssertTrue(waitUntilText(identified("launcher.slot.12"), contains: "Panel Fixture"))
    click(identified("launcher.quick.close"))
    XCTAssertTrue(waitForNonexistence(identified("launcher.quick.popover")))
    XCTAssertTrue(waitUntilText(identified("launcher.slot.12"), contains: "Panel Fixture"))
  }

  func testRuntimeConflictStaysVisibleWhenOpeningAndClosingShortcutOptions() throws {
    launch(fixture: "runtime-conflict")

    let qState = identified("launcher.slot.12")
    XCTAssertTrue(qState.waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntilText(qState, contains: "冲突"))
    openExistingQuickBinding(keyCode: qKeyCode)
    let shortcutOptions = identified("launcher.quick.shortcut-options")
    XCTAssertTrue(shortcutOptions.waitForExistence(timeout: 5))
    click(shortcutOptions)
    XCTAssertTrue(identified("launcher.quick.modifier.control").waitForExistence(timeout: 5))
    click(identified("launcher.quick.close"))
    XCTAssertTrue(waitUntilText(qState, contains: "冲突"))
  }

  func testDisableAndEnableAllGlobalShortcutsFromSettings() throws {
    launch(fixture: "one-direct")

    let qState = identified("launcher.slot.12")
    XCTAssertTrue(qState.waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntilText(qState, contains: "⌘⌥Q"))

    openSettings()
    click(identified("launcher.settings.directEnabled"))
    XCTAssertTrue(
      waitUntilText(identified("launcher.settings.feedback"), contains: "已保存")
    )
    click(identified("launcher.settings.done"))
    XCTAssertTrue(waitUntilText(qState, contains: "已暂停"))

    openSettings()
    click(identified("launcher.settings.directEnabled"))
    XCTAssertTrue(
      waitUntilText(identified("launcher.settings.feedback"), contains: "已保存")
    )
    click(identified("launcher.settings.done"))
    XCTAssertTrue(waitUntilText(qState, contains: "⌘⌥Q"))
    XCTAssertFalse(waitUntilText(qState, contains: "已暂停", timeout: 1))
  }

  func testSavedBindingSurvivesHostRelaunchInSameTemporaryDirectory() throws {
    launch(fixture: "empty")
    assertGridVisibleWithoutQuickBinding(slotKeyCode: qKeyCode)
    openQuickBinding(keyCode: qKeyCode)
    bindWebURL("restart.example")

    let qState = identified("launcher.slot.12")
    XCTAssertTrue(waitUntilText(qState, contains: "restart.example"))
    XCTAssertTrue(waitUntilText(qState, contains: "⌃Q"))
    app.terminate()

    launch(fixture: nil, reusingStorage: true)
    let relaunchedQState = identified("launcher.slot.12")
    XCTAssertTrue(relaunchedQState.waitForExistence(timeout: 10))
    XCTAssertTrue(waitUntilText(relaunchedQState, contains: "restart.example"))
    XCTAssertTrue(waitUntilText(relaunchedQState, contains: "⌃Q"))
  }

  private func launch(fixture: String?, reusingStorage: Bool = false) {
    app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing",
      "--show-panel",
      "--fake-hotkey-registrar",
      "--fake-target-opener",
      "--storage-directory", storageDirectory.path,
    ]
    if let fixture {
      app.launchArguments += ["--fixture", fixture]
    }
    if reusingStorage {
      app.launchArguments.append("--reuse-ui-test-storage")
    }
    app.launch()
    XCTAssertTrue(launcherWindow.waitForExistence(timeout: 12))
  }

  private func openSettings() {
    let more = identified("launcher.more")
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    click(more)
    let settings = app.menuItems["快捷启动设置…"].firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    click(settings)
    XCTAssertTrue(identified("launcher.settings").waitForExistence(timeout: 5))
  }

  private func openQuickBinding(keyCode: UInt16) {
    let slot = identified("launcher.slot.\(keyCode)")
    XCTAssertTrue(slot.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilEnabled(slot))
    click(slot)
    XCTAssertTrue(identified("launcher.quick.popover").waitForExistence(timeout: 5))
  }

  private func openExistingQuickBinding(keyCode: UInt16) {
    let slot = identified("launcher.slot.\(keyCode)")
    XCTAssertTrue(slot.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilEnabled(slot))
    slot.rightClick()
    let replaceTarget = app.menuItems["更换目标…"].firstMatch
    XCTAssertTrue(replaceTarget.waitForExistence(timeout: 5))
    click(replaceTarget)
    XCTAssertTrue(identified("launcher.quick.popover").waitForExistence(timeout: 5))
  }

  private func assertGridVisibleWithoutQuickBinding(slotKeyCode: UInt16) {
    XCTAssertFalse(identified("launcher.quick.popover").exists)
    XCTAssertTrue(identified("launcher.keyboard").waitForExistence(timeout: 5))
    let slot = identified("launcher.slot.\(slotKeyCode)")
    XCTAssertTrue(slot.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilEnabled(slot))
    XCTAssertFalse(identified("launcher.quick.popover").exists)
  }

  private func bindWebURL(_ value: String) {
    let webButton = identified("launcher.quick.kind.网址")
    XCTAssertTrue(webButton.waitForExistence(timeout: 5))
    click(webButton)

    let field = identified("launcher.quick.web.input")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    click(field)
    field.typeText(value)
    let confirm = identified("launcher.quick.web.confirm")
    XCTAssertTrue(waitUntilEnabled(confirm))
    click(confirm)
  }

  private func identified(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private var launcherWindow: XCUIElement {
    app.dialogs.matching(identifier: "launcher.panel.window").firstMatch
  }

  private func readableText(_ element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty { return value }
    return element.label
  }

  private func click(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
  }

  private func waitUntilText(
    _ element: XCUIElement,
    contains fragment: String,
    timeout: TimeInterval = 8
  ) -> Bool {
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement, element.exists else { return false }
      return self.readableText(element).contains(fragment)
    }
    return XCTWaiter.wait(
      for: [expectation(for: predicate, evaluatedWith: element)],
      timeout: timeout
    ) == .completed
  }

  private func waitUntilEnabled(
    _ element: XCUIElement,
    timeout: TimeInterval = 8
  ) -> Bool {
    let predicate = NSPredicate(format: "exists == true AND enabled == true")
    return XCTWaiter.wait(
      for: [expectation(for: predicate, evaluatedWith: element)],
      timeout: timeout
    ) == .completed
  }

  private func waitForNonexistence(
    _ element: XCUIElement,
    timeout: TimeInterval = 8
  ) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    return XCTWaiter.wait(
      for: [expectation(for: predicate, evaluatedWith: element)],
      timeout: timeout
    ) == .completed
  }
}
