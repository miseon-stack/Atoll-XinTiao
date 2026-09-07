import Foundation
import XCTest

@testable import ShortcutLauncherCore

final class BindingRuntimeStateTests: XCTestCase {
  private let slot = PhysicalKeyCode.q
  private let bindingID = BindingID(rawValue: "binding-q")
  private let hotkey = HotkeyDefinition(
    keyCode: PhysicalKeyCode.q,
    modifiers: [.command, .option]
  )

  func testUnboundState() {
    let presentation = resolve(configuration: LauncherConfiguration())

    XCTAssertEqual(presentation.runtimeState, .unbound)
    XCTAssertNil(presentation.bindingID)
    XCTAssertNil(presentation.displayName)
  }

  func testPanelOnlyState() {
    let configuration = makeConfiguration(includesDirectHotkey: false)

    XCTAssertEqual(resolve(configuration: configuration).runtimeState, .panelOnly)
  }

  func testEnabledRequiresActualRegistration() {
    let configuration = makeConfiguration(directModeEnabled: true)
    let ledger = RegistrationLedgerSnapshot(registeredBindingIDs: [bindingID])

    XCTAssertEqual(
      resolve(configuration: configuration, ledger: ledger).runtimeState,
      .enabled(hotkey)
    )
  }

  func testMissingExpectedRegistrationIsConflicted() {
    let configuration = makeConfiguration(directModeEnabled: true)

    XCTAssertEqual(
      resolve(configuration: configuration).runtimeState,
      .conflicted(hotkey)
    )
  }

  func testExplicitConflictWinsOverRegistration() {
    let configuration = makeConfiguration(directModeEnabled: true)
    let ledger = RegistrationLedgerSnapshot(
      registeredBindingIDs: [bindingID],
      conflictedBindingIDs: [bindingID]
    )

    XCTAssertEqual(
      resolve(configuration: configuration, ledger: ledger).runtimeState,
      .conflicted(hotkey)
    )
  }

  func testConfigurationPauseState() {
    let configuration = makeConfiguration(directModeEnabled: false)

    XCTAssertEqual(resolve(configuration: configuration).runtimeState, .paused(hotkey))
  }

  func testRuntimePauseWinsOverRegisteredEnabledState() {
    let configuration = makeConfiguration(directModeEnabled: true)
    let ledger = RegistrationLedgerSnapshot(
      registeredBindingIDs: [bindingID],
      directHotkeysPaused: true
    )

    XCTAssertEqual(
      resolve(configuration: configuration, ledger: ledger).runtimeState,
      .paused(hotkey)
    )
  }

  func testPendingStateUsesDraftCandidate() {
    let configuration = makeConfiguration(directModeEnabled: true)
    var session = BindingEditSession(configuration: configuration)
    let candidate = HotkeyDefinition(keyCode: 13, modifiers: [.control, .option])
    session.setDirectHotkey(candidate, at: slot)
    let ledger = RegistrationLedgerSnapshot(
      registeredBindingIDs: [bindingID],
      conflictedBindingIDs: [bindingID],
      directHotkeysPaused: true
    )

    XCTAssertEqual(
      resolve(
        configuration: configuration,
        session: session,
        ledger: ledger
      ).runtimeState,
      .pending(candidate: candidate)
    )
  }

  func testPendingGlobalModeChangeAffectsConfiguredDirectBinding() {
    let configuration = makeConfiguration(directModeEnabled: false)
    var session = BindingEditSession(configuration: configuration)
    session.draft.directModeEnabled = true

    XCTAssertEqual(
      resolve(configuration: configuration, session: session).runtimeState,
      .pending(candidate: hotkey)
    )
  }

  func testTargetUnavailableHasHighestPriority() {
    let configuration = makeConfiguration(directModeEnabled: true)
    var session = BindingEditSession(configuration: configuration)
    let candidate = HotkeyDefinition(keyCode: 13, modifiers: [.control, .option])
    session.setDirectHotkey(candidate, at: slot)
    let ledger = RegistrationLedgerSnapshot(
      registeredBindingIDs: [bindingID],
      conflictedBindingIDs: [bindingID],
      directHotkeysPaused: true
    )

    XCTAssertEqual(
      resolve(
        configuration: configuration,
        session: session,
        ledger: ledger,
        unavailable: [bindingID]
      ).runtimeState,
      .targetUnavailable(hotkey: candidate)
    )
  }

  func testConflictHasPriorityOverPause() {
    let configuration = makeConfiguration(directModeEnabled: false)
    let ledger = RegistrationLedgerSnapshot(
      conflictedBindingIDs: [bindingID],
      directHotkeysPaused: true
    )

    XCTAssertEqual(
      resolve(configuration: configuration, ledger: ledger).runtimeState,
      .conflicted(hotkey)
    )
  }

  func testPendingDeletionRetainsCommittedMetadata() {
    let configuration = makeConfiguration(directModeEnabled: true)
    var session = BindingEditSession(configuration: configuration)
    session.removeBinding(at: slot)
    let presentation = resolve(
      configuration: configuration,
      session: session,
      ledger: RegistrationLedgerSnapshot(registeredBindingIDs: [bindingID])
    )

    XCTAssertEqual(presentation.runtimeState, .pending(candidate: nil))
    XCTAssertEqual(presentation.bindingID, bindingID)
    XCTAssertEqual(presentation.displayName, "Example")
  }

  func testInjectedLabelsDrivePanelAndDirectPresentation() {
    let configuration = makeConfiguration(directModeEnabled: true)
    let input = BindingStateInputSnapshot(
      committedConfiguration: configuration,
      registrationLedger: RegistrationLedgerSnapshot(
        registeredBindingIDs: [bindingID]
      ),
      keyLabels: KeyLabelSnapshot(revision: 1, labels: [slot: "你"])
    )
    let presentation = BindingStateResolver.resolve(slotKeyCode: slot, from: input)

    XCTAssertEqual(presentation.panelKeyLabel, "你")
    XCTAssertEqual(presentation.directHotkeyLabel, "⌥⌘你")
  }

  func testBlankInjectedLabelFallsBackToCatalog() {
    let input = BindingStateInputSnapshot(
      committedConfiguration: LauncherConfiguration(),
      keyLabels: KeyLabelSnapshot(revision: 1, labels: [slot: "  "])
    )

    XCTAssertEqual(
      BindingStateResolver.resolve(slotKeyCode: slot, from: input).panelKeyLabel,
      "Q"
    )
  }

  func testResolveAllReturnsEveryCatalogSlotInCatalogOrder() {
    let input = BindingStateInputSnapshot(
      committedConfiguration: LauncherConfiguration()
    )

    let presentations = BindingStateResolver.resolveAll(from: input)

    XCTAssertEqual(presentations.count, 38)
    XCTAssertEqual(presentations.map(\.slotKeyCode), KeySlotCatalog.all.map(\.keyCode))
    XCTAssertTrue(presentations.allSatisfy { $0.runtimeState == .unbound })
  }

  private func resolve(
    configuration: LauncherConfiguration,
    session: BindingEditSession? = nil,
    ledger: RegistrationLedgerSnapshot = RegistrationLedgerSnapshot(),
    unavailable: Set<BindingID> = []
  ) -> BindingPresentation {
    BindingStateResolver.resolve(
      slotKeyCode: slot,
      from: BindingStateInputSnapshot(
        committedConfiguration: configuration,
        editSession: session,
        registrationLedger: ledger,
        unavailableTargetBindingIDs: unavailable
      )
    )
  }

  private func makeConfiguration(
    directModeEnabled: Bool = false,
    includesDirectHotkey: Bool = true
  ) -> LauncherConfiguration {
    LauncherConfiguration(
      directModeEnabled: directModeEnabled,
      bindings: [
        slot: BindingRecord(
          id: bindingID,
          physicalKeyCode: slot,
          target: LaunchTarget(
            kind: .web,
            displayName: "Example",
            lastKnownURL: URL(string: "https://example.com")!
          ),
          directHotkey: includesDirectHotkey ? hotkey : nil
        )
      ]
    )
  }
}
