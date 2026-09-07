import XCTest

@testable import ShortcutLauncherCore

final class LauncherOperationResultsTests: XCTestCase {
  private let bindingID = BindingID(rawValue: "binding-a")
  private let hotkey = HotkeyDefinition(keyCode: 0, modifiers: [.command, .option])

  func testCommitResultsAreStableEquatableValues() {
    let issue = LauncherIssue(
      code: .duplicateHotkey,
      bindingID: bindingID,
      relatedBindingID: BindingID(rawValue: "binding-b"),
      combination: hotkey
    )

    XCTAssertEqual(
      LauncherCommitResult.committed(
        configurationRevision: 7,
        enabled: [bindingID]
      ),
      .committed(configurationRevision: 7, enabled: [bindingID])
    )
    XCTAssertEqual(
      LauncherCommitResult.validationFailed([issue]),
      .validationFailed([issue])
    )
    XCTAssertEqual(
      LauncherCommitResult.registrationFailed(
        bindingID: bindingID,
        combination: hotkey
      ),
      .registrationFailed(bindingID: bindingID, combination: hotkey)
    )
    XCTAssertEqual(
      LauncherCommitResult.persistenceFailed(code: .writeFailed),
      .persistenceFailed(code: .writeFailed)
    )
    XCTAssertEqual(
      LauncherCommitResult.rejected(reason: .moduleStopping),
      .rejected(reason: .moduleStopping)
    )
  }

  func testRetryResultsContainOnlyStableBindingIdentity() {
    XCTAssertEqual(
      HotkeyRetryResult.enabled(bindingID),
      .enabled(bindingID)
    )
    XCTAssertEqual(
      HotkeyRetryResult.stillConflicted(bindingID),
      .stillConflicted(bindingID)
    )
    XCTAssertEqual(
      HotkeyRetryResult.notConfigured(bindingID),
      .notConfigured(bindingID)
    )
    XCTAssertEqual(HotkeyRetryResult.moduleUnavailable, .moduleUnavailable)
  }

  func testExecutionResultsUseStableFailureCodes() {
    XCTAssertEqual(ExecutionResult.accepted(bindingID), .accepted(bindingID))
    XCTAssertEqual(
      ExecutionResult.targetUnavailable(bindingID),
      .targetUnavailable(bindingID)
    )
    XCTAssertEqual(
      ExecutionResult.failed(bindingID, code: .targetResolutionFailed),
      .failed(bindingID, code: .targetResolutionFailed)
    )
    XCTAssertEqual(ExecutionFailureCode.openRejected.rawValue, "openRejected")
  }

  func testValidationIssuesProjectLegacyPrivateBindingIdentifiers() {
    let privateID = BindingID(rawValue: "file:///private-fixture/Documents/private.txt")
    let relatedPrivateID = BindingID(rawValue: "https://private.example/account?id=42")

    let issue = LauncherIssue(
      code: .duplicateHotkey,
      bindingID: privateID,
      relatedBindingID: relatedPrivateID,
      combination: hotkey
    )

    XCTAssertEqual(issue.bindingID, privateID.hostSafeProjection)
    XCTAssertEqual(issue.relatedBindingID, relatedPrivateID.hostSafeProjection)
    XCTAssertFalse(String(reflecting: issue).contains("/private-fixture"))
    XCTAssertFalse(String(reflecting: issue).contains("private.example"))
  }
}
