import Foundation
import XCTest

@testable import ShortcutLauncherCore

final class LauncherHostContractTests: XCTestCase {
  private let bindingID = BindingID(rawValue: "binding-q")
  private let hotkey = HotkeyDefinition(
    keyCode: PhysicalKeyCode.q,
    modifiers: [.command, .option]
  )

  func testLifecycleAndIssueCodesAreStableValues() {
    XCTAssertEqual(LauncherLifecycleState.running.rawValue, "running")
    XCTAssertEqual(
      Set(LauncherLifecycleState.allCases),
      [.stopped, .starting, .running, .stopping, .unavailable]
    )
    XCTAssertEqual(
      LauncherRuntimeIssueCode.directHotkeyConflict.rawValue,
      "directHotkeyConflict"
    )
  }

  func testRuntimeSummaryConstructsFromBindingPresentation() {
    let presentation = BindingPresentation(
      bindingID: bindingID,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: .application,
      displayName: "WeChat",
      panelKeyLabel: "Q",
      directHotkeyLabel: "⌥⌘Q",
      runtimeState: .enabled(hotkey)
    )

    let summary = BindingRuntimeSummary(presentation: presentation)

    XCTAssertEqual(summary.id, PhysicalKeyCode.q)
    XCTAssertEqual(summary.bindingID, bindingID)
    XCTAssertEqual(summary.targetKind, .application)
    XCTAssertEqual(summary.displayName, "WeChat")
    XCTAssertEqual(summary.runtimeState, .enabled(hotkey))
  }

  func testRuntimeSummaryReplacesURLAndPathLikeNames() {
    let privateValues = [
      "https://example.com/private?token=secret",
      "file:///private-fixture/Documents/private.pdf",
      "/private-fixture/Documents/private.pdf",
      "~/Documents/private.pdf",
      "folder\\private.pdf",
      "www.example.com/#private",
    ]

    for privateValue in privateValues {
      let summary = BindingRuntimeSummary(
        bindingID: bindingID,
        slotKeyCode: PhysicalKeyCode.q,
        targetKind: .file,
        displayName: privateValue,
        runtimeState: .panelOnly
      )

      XCTAssertEqual(summary.displayName, LaunchTargetKind.file.displayName)
      XCTAssertFalse(summary.displayName?.contains("private") == true)
    }
  }

  func testLegacyBindingIdentifiersRemainReadableButPrivateLocationsUseStableHostAliases() throws {
    for compatibleIdentifier in ["中文绑定", "legacy binding", "legacy:binding:id"] {
      let configuration = LauncherConfiguration(bindings: [
        0: BindingRecord(
          id: BindingID(rawValue: compatibleIdentifier),
          physicalKeyCode: 0,
          target: LaunchTarget(
            kind: .web,
            displayName: "Safe",
            lastKnownURL: try XCTUnwrap(URL(string: "https://safe.example"))
          )
        )
      ])
      let encoded = try JSONEncoder().encode(configuration)
      let decoded = try JSONDecoder().decode(LauncherConfiguration.self, from: encoded)

      XCTAssertNoThrow(try ConfigurationValidator.validate(decoded))
      XCTAssertEqual(decoded.bindings[0]?.id.rawValue, compatibleIdentifier)
    }

    let privateID = BindingID(rawValue: "/private-fixture/Documents/secret.pdf")
    let first = BindingRuntimeSummary(
      bindingID: privateID,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: .file,
      displayName: "Document",
      runtimeState: .panelOnly
    )
    let second = BindingRuntimeSummary(
      bindingID: privateID,
      slotKeyCode: 0,
      targetKind: .file,
      displayName: "Document",
      runtimeState: .panelOnly
    )
    let event = LauncherEvent(name: .bindingExecuted, bindingID: privateID)

    let projectedID = try XCTUnwrap(first.bindingID)
    XCTAssertEqual(projectedID, second.bindingID)
    XCTAssertEqual(projectedID, event.bindingID)
    XCTAssertNotEqual(projectedID, privateID)
    XCTAssertTrue(projectedID.rawValue.hasPrefix("opaque-sha256-"))
    XCTAssertFalse(String(reflecting: first).contains("/private-fixture"))
    XCTAssertFalse(String(reflecting: event).contains("/private-fixture"))

    let configuration = LauncherConfiguration(bindings: [
      PhysicalKeyCode.q: BindingRecord(
        id: privateID,
        physicalKeyCode: PhysicalKeyCode.q,
        target: LaunchTarget(
          kind: .file,
          displayName: "Document",
          lastKnownURL: URL(fileURLWithPath: "/private-fixture/Documents/secret.pdf")
        )
      )
    ])
    XCTAssertEqual(
      configuration.keyCode(forHostFacingBindingID: projectedID),
      PhysicalKeyCode.q
    )
    XCTAssertEqual(configuration.binding(hostFacingID: projectedID)?.id, privateID)
  }

  func testURISchemeBindingIdentifiersAndDisplayNamesAreProjected() {
    let privateValues = [
      "mailto:private@example.com",
      "data:text/plain,secret",
      "https:private.example",
    ]

    for privateValue in privateValues {
      let projected = BindingID(rawValue: privateValue).hostSafeProjection
      XCTAssertTrue(projected.rawValue.hasPrefix("opaque-sha256-"))
      XCTAssertFalse(projected.rawValue.contains("private"))

      let summary = BindingRuntimeSummary(
        bindingID: BindingID(rawValue: "safe-id"),
        slotKeyCode: PhysicalKeyCode.q,
        targetKind: .web,
        displayName: privateValue,
        runtimeState: .panelOnly
      )
      XCTAssertEqual(summary.displayName, LaunchTargetKind.web.displayName)
    }
  }

  func testReservedProjectionNamespaceCannotImpersonateAnotherBinding() throws {
    let privateID = BindingID(rawValue: "file:///private-fixture/first")
    let firstPublicID = privateID.hostSafeProjection
    let namespaceLookalikeID = BindingID(rawValue: firstPublicID.rawValue)
    let configuration = LauncherConfiguration(bindings: [
      0: BindingRecord(
        id: privateID,
        physicalKeyCode: 0,
        target: LaunchTarget(
          kind: .web,
          displayName: "First",
          lastKnownURL: try XCTUnwrap(URL(string: "https://first.example"))
        )
      ),
      1: BindingRecord(
        id: namespaceLookalikeID,
        physicalKeyCode: 1,
        target: LaunchTarget(
          kind: .web,
          displayName: "Second",
          lastKnownURL: try XCTUnwrap(URL(string: "https://second.example"))
        )
      ),
    ])

    XCTAssertNoThrow(try ConfigurationValidator.validate(configuration))
    XCTAssertNotEqual(privateID.hostSafeProjection, namespaceLookalikeID.hostSafeProjection)
    XCTAssertEqual(configuration.binding(id: firstPublicID)?.id, namespaceLookalikeID)
    XCTAssertEqual(configuration.binding(hostFacingID: firstPublicID)?.id, privateID)
    XCTAssertEqual(
      configuration.binding(hostFacingID: namespaceLookalikeID.hostSafeProjection)?.id,
      namespaceLookalikeID
    )
  }

  func testRuntimeSummaryNormalizesEmptyControlAndOversizedNames() {
    let empty = BindingRuntimeSummary(
      bindingID: bindingID,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: .web,
      displayName: " \n\t ",
      runtimeState: .panelOnly
    )
    let controlled = BindingRuntimeSummary(
      bindingID: bindingID,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: .application,
      displayName: "We\u{0000}Chat",
      runtimeState: .panelOnly
    )
    let oversized = BindingRuntimeSummary(
      bindingID: bindingID,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: .folder,
      displayName: String(repeating: "A", count: 120),
      runtimeState: .panelOnly
    )

    XCTAssertEqual(empty.displayName, "网页")
    XCTAssertEqual(controlled.displayName, "WeChat")
    XCTAssertEqual(oversized.displayName?.count, 80)
  }

  func testUnboundSummaryCannotCarryANameWithoutATargetKind() {
    let summary = BindingRuntimeSummary(
      bindingID: nil,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: nil,
      displayName: "private value",
      runtimeState: .unbound
    )

    XCTAssertNil(summary.displayName)
  }

  func testSnapshotCanonicalizesBindingAndIssueOrder() {
    let q = BindingRuntimeSummary(
      bindingID: bindingID,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: .application,
      displayName: "WeChat",
      runtimeState: .enabled(hotkey)
    )
    let a = BindingRuntimeSummary(
      bindingID: nil,
      slotKeyCode: 0,
      targetKind: nil,
      displayName: nil,
      runtimeState: .unbound
    )

    let snapshot = LauncherRuntimeSnapshot(
      lifecycleState: .running,
      configurationRevision: 12,
      panelHotkey: .defaultPanel,
      directHotkeysPaused: false,
      bindings: [q, a],
      issueCodes: [
        .targetUnavailable,
        .directHotkeyConflict,
        .targetUnavailable,
      ]
    )

    XCTAssertEqual(snapshot.lifecycleState, .running)
    XCTAssertEqual(snapshot.configurationRevision, 12)
    XCTAssertEqual(snapshot.panelHotkey, .defaultPanel)
    XCTAssertFalse(snapshot.directHotkeysPaused)
    XCTAssertEqual(snapshot.bindings.map(\.slotKeyCode), [0, PhysicalKeyCode.q])
    XCTAssertEqual(
      snapshot.issueCodes,
      [.directHotkeyConflict, .targetUnavailable]
    )
    XCTAssertEqual(snapshot, snapshot)
  }

  func testSnapshotStoredSurfaceContainsNoPrivateResourceTypesOrValues() {
    let summary = BindingRuntimeSummary(
      bindingID: bindingID,
      slotKeyCode: PhysicalKeyCode.q,
      targetKind: .file,
      displayName: "/private-fixture/secret.pdf",
      runtimeState: .targetUnavailable(hotkey: hotkey)
    )
    let snapshot = LauncherRuntimeSnapshot(
      lifecycleState: .running,
      configurationRevision: 4,
      panelHotkey: .defaultPanel,
      directHotkeysPaused: false,
      bindings: [summary],
      issueCodes: [.targetUnavailable]
    )

    let storageLabels = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))
    XCTAssertEqual(
      storageLabels,
      [
        "lifecycleState",
        "configurationRevision",
        "panelHotkey",
        "directHotkeysPaused",
        "bindings",
        "issueCodes",
      ]
    )
    XCTAssertFalse(containsValue(ofType: URL.self, in: snapshot))
    XCTAssertFalse(containsValue(ofType: Data.self, in: snapshot))
    XCTAssertFalse(String(reflecting: snapshot).contains("/private-fixture"))
    XCTAssertFalse(String(reflecting: snapshot).contains("secret.pdf"))
  }

  func testCommitRequestIsRevisionAwareAndDoesNotChangeSchema() {
    let configuration = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [:]
    )
    let request = LauncherCommitRequest(
      expectedConfigurationRevision: 9,
      candidateConfiguration: configuration
    )

    XCTAssertEqual(request.expectedConfigurationRevision, 9)
    XCTAssertEqual(request.candidateConfiguration, configuration)
    XCTAssertEqual(
      request.candidateConfiguration.schemaVersion,
      LauncherConfiguration.currentSchemaVersion
    )
    XCTAssertEqual(request, request)
  }

  @MainActor
  func testControllingProtocolCanBeAdoptedWithoutReplacingLegacyExecute() async {
    let controller: any ShortcutLauncherControlling = FakeController()

    XCTAssertEqual(controller.snapshot.lifecycleState, .stopped)
    let result = await controller.executeWithResult(
      bindingID: bindingID,
      source: .panelClick
    )
    XCTAssertEqual(result, .accepted(bindingID))
  }

  private func containsValue<T>(ofType type: T.Type, in root: Any) -> Bool {
    if root is T { return true }
    return Mirror(reflecting: root).children.contains { child in
      containsValue(ofType: type, in: child.value)
    }
  }
}

@MainActor
private final class FakeController: ShortcutLauncherControlling {
  var snapshot = LauncherRuntimeSnapshot(
    lifecycleState: .stopped,
    configurationRevision: 0,
    panelHotkey: .defaultPanel,
    directHotkeysPaused: true,
    bindings: []
  )

  func start() async throws {}
  func stop() async {}
  func presentPanel() {}
  func dismissPanel() {}

  func commit(_ request: LauncherCommitRequest) async -> LauncherCommitResult {
    .committed(
      configurationRevision: request.expectedConfigurationRevision + 1,
      enabled: []
    )
  }

  func retryDirectHotkey(bindingID: BindingID) async -> HotkeyRetryResult {
    .notConfigured(bindingID)
  }

  func executeWithResult(
    bindingID: BindingID,
    source: TriggerSource
  ) async -> ExecutionResult {
    .accepted(bindingID)
  }
}
