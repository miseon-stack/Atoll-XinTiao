import Foundation
import ShortcutLauncherCore
import ShortcutLauncherUI
import XCTest

@MainActor
final class ShortcutLauncherPublicAPITests: XCTestCase {
  func testExternalHostCanConstructAndCallStableContract() async {
    let storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shortcut-launcher-public-api-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let hostConfiguration = ShortcutLauncherHostConfiguration(
      storageDirectory: storageDirectory,
      bookmarkPolicy: .lastKnownURLOnly
    )
    let uiConfiguration = ShortcutLauncherUIConfiguration(
      theme: LauncherTheme(
        title: "External Host",
        subtitle: "Public API compilation proof"
      )
    )
    let controller: any ShortcutLauncherControlling = ShortcutLauncherModule(
      hostConfiguration: hostConfiguration,
      uiConfiguration: uiConfiguration
    )

    XCTAssertEqual(controller.snapshot.lifecycleState, .stopped)
    XCTAssertEqual(controller.snapshot.configurationRevision, 0)

    controller.dismissPanel()

    let missingBindingID = BindingID(rawValue: "public-api-missing-binding")
    let executionResult = await controller.executeWithResult(
      bindingID: missingBindingID,
      source: .panelClick
    )
    XCTAssertEqual(
      executionResult,
      .failed(missingBindingID, code: .moduleUnavailable)
    )
    let retryResult = await controller.retryDirectHotkey(bindingID: missingBindingID)
    XCTAssertEqual(retryResult, .notConfigured(missingBindingID))

    await controller.stop()
    XCTAssertEqual(controller.snapshot.lifecycleState, .stopped)
  }
}
