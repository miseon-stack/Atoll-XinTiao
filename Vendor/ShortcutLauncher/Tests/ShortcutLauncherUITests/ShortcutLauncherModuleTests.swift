import AppKit
import Darwin
import Foundation
import XCTest

@testable import ShortcutLauncherCore
@testable import ShortcutLauncherUI

@MainActor
final class ShortcutLauncherModuleTests: XCTestCase {
  func testModuleStartStopStartUsesSingleRegistrationPerRun() async throws {
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar)

    try await module.start()
    try await module.start()
    XCTAssertEqual(registrar.registerCount, 1)

    await module.stop()
    try await module.start()
    XCTAssertEqual(registrar.registerCount, 2)
    XCTAssertEqual(registrar.unregisterAllCount, 1)
  }

  func testKeyLabelObservationFollowsModuleLifecycleWithoutDuplicates() async throws {
    let provider = LifecycleKeyLabelProvider()
    let module = makeModule(keyLabelProvider: provider)

    XCTAssertEqual(provider.startCount, 0)
    XCTAssertEqual(provider.refreshCount, 0)

    try await module.start()
    try await module.start()
    XCTAssertEqual(provider.startCount, 1)
    XCTAssertEqual(provider.refreshCount, 1)

    await module.stop()
    await module.stop()
    XCTAssertEqual(provider.stopCount, 1)

    try await module.start()
    XCTAssertEqual(provider.startCount, 2)
    XCTAssertEqual(provider.refreshCount, 2)
    await module.stop()
    XCTAssertEqual(provider.stopCount, 2)
  }

  func testSharedOwnerLeaseRejectsSecondActiveModuleAndRecoversAfterStop() async throws {
    let lease = HotkeyOwnerLease()
    let firstRegistrar = ModuleFakeHotkeyRegistrar()
    let secondRegistrar = ModuleFakeHotkeyRegistrar()
    let first = makeModule(registrar: firstRegistrar, ownerLease: lease)
    let second = makeModule(registrar: secondRegistrar, ownerLease: lease)

    try await first.start()
    do {
      try await second.start()
      XCTFail("Expected the second active owner to be rejected")
    } catch let error as LauncherError {
      XCTAssertEqual(error, .moduleAlreadyActive)
    }

    XCTAssertEqual(firstRegistrar.registrations[.panel], .defaultPanel)
    XCTAssertTrue(secondRegistrar.registrations.isEmpty)

    await first.stop()
    try await second.start()
    XCTAssertEqual(secondRegistrar.registrations[.panel], .defaultPanel)
  }

  func testSnapshotReportsPanelRegistrationRecoveryFailureUntilRestart() async throws {
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar)
    try await module.start()

    let sessionID = UUID()
    let becameReady = await module.beginHotkeyRecorderSession(sessionID)
    XCTAssertTrue(becameReady)
    registrar.failingIDs = [.panel]
    await module.endHotkeyRecorderSession(sessionID)

    XCTAssertTrue(module.snapshot.issueCodes.contains(.panelHotkeyUnavailable))
    XCTAssertTrue(module.snapshot.issueCodes.contains(.registrationRecoveryIncomplete))
    XCTAssertEqual(module.snapshot.lifecycleState, .running)

    registrar.failingIDs.removeAll()
    await module.stop()
    try await module.start()
    XCTAssertFalse(module.snapshot.issueCodes.contains(.panelHotkeyUnavailable))
    XCTAssertFalse(module.snapshot.issueCodes.contains(.registrationRecoveryIncomplete))
  }

  func testPublicDependencyInjectionInitializersShareTheProcessOwnerByDefault() async throws {
    let firstRegistrar = ModuleFakeHotkeyRegistrar()
    let secondRegistrar = ModuleFakeHotkeyRegistrar()
    let first = ShortcutLauncherModule(
      registrar: firstRegistrar,
      store: MemoryConfigurationStore(),
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener()
    )
    let second = ShortcutLauncherModule(
      registrar: secondRegistrar,
      store: MemoryConfigurationStore(),
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener()
    )

    try await first.start()
    do {
      try await second.start()
      XCTFail("Expected public DI initializers to enforce process-wide ownership")
      await second.stop()
    } catch let error as LauncherError {
      XCTAssertEqual(error, .moduleAlreadyActive)
    }

    XCTAssertTrue(secondRegistrar.registrations.isEmpty)
    await first.stop()
  }

  func testFailedStartReturnsOwnerLeaseToAnotherModule() async throws {
    let lease = HotkeyOwnerLease()
    let failingRegistrar = ModuleFakeHotkeyRegistrar()
    failingRegistrar.failingIDs = [.panel]
    let failed = makeModule(registrar: failingRegistrar, ownerLease: lease)
    let replacementRegistrar = ModuleFakeHotkeyRegistrar()
    let replacement = makeModule(registrar: replacementRegistrar, ownerLease: lease)

    do {
      try await failed.start()
      XCTFail("Expected panel registration to fail")
    } catch {
      XCTAssertTrue(failingRegistrar.registrations.isEmpty)
    }

    try await replacement.start()
    XCTAssertEqual(replacementRegistrar.registrations[.panel], .defaultPanel)
  }

  func testStartStopStartRestoresEnabledDirectShortcutExactlyOnce() async throws {
    let item = record(id: "wechat", slot: PhysicalKeyCode.q, name: "WeChat", hotkeyKey: 3)
    let configuration = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [PhysicalKeyCode.q: item]
    )
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(configuration: configuration)
    )

    try await module.start()
    XCTAssertEqual(registrar.registerCount, 2)
    XCTAssertEqual(registrar.registrations.count, 2)

    await module.stop()
    XCTAssertTrue(registrar.registrations.isEmpty)

    try await module.start()
    XCTAssertEqual(registrar.registerCount, 4)
    XCTAssertEqual(registrar.registrations[.panel], configuration.panelHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], item.directHotkey)
  }

  func testOneHundredStartStopCyclesDoNotDuplicateRegistration() async throws {
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar)

    for _ in 0..<100 {
      try await module.start()
      await module.stop()
    }

    XCTAssertEqual(registrar.registerCount, 100)
    XCTAssertEqual(registrar.unregisterAllCount, 100)
    XCTAssertTrue(registrar.registrations.isEmpty)
  }

  func testDirectModeRegistersIndependentHotkeysAndKeepsOtherBindingOnConflict() async throws {
    let a = record(id: "a", slot: 0, name: "A", hotkeyKey: 3)
    let s = record(id: "s", slot: 1, name: "S", hotkeyKey: 4)
    let registrar = ModuleFakeHotkeyRegistrar()
    registrar.failingIDs = [.direct(bindingID: s.id)]
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: a, 1: s])
    )
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(registrar: registrar, store: store, opener: opener)

    try await module.start()

    XCTAssertEqual(module.directConflictKeyCodes, [1])
    XCTAssertNotNil(registrar.registrations[.direct(bindingID: a.id)])
    XCTAssertNil(registrar.registrations[.direct(bindingID: s.id)])

    registrar.trigger(.direct(bindingID: a.id))
    await Task.yield()
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["A"])
  }

  func testUnrelatedCommitPreservesStartupConflictUntilExplicitRetry() async throws {
    let a = record(id: "a", slot: 0, name: "A", hotkeyKey: 3)
    let s = record(id: "s", slot: 1, name: "S", hotkeyKey: 4)
    let registrar = ModuleFakeHotkeyRegistrar()
    registrar.failingIDs = [.direct(bindingID: s.id)]
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: a, 1: s])
    )
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    XCTAssertNil(registrar.registrations[.direct(bindingID: s.id)])

    registrar.failingIDs.removeAll()
    module.beginEditing()
    module.bindWebURL("https://updated.example", to: 0)
    await module.commitEditing()

    XCTAssertNil(registrar.registrations[.direct(bindingID: s.id)])
    XCTAssertEqual(module.directConflictKeyCodes, [1])
    XCTAssertEqual(store.configuration.bindings[0]?.target.displayName, "updated.example")

    let retryResult = await module.retryDirectHotkey(bindingID: s.id)
    XCTAssertEqual(retryResult, .enabled(s.id))
    XCTAssertNotNil(registrar.registrations[.direct(bindingID: s.id)])
    XCTAssertTrue(module.directConflictKeyCodes.isEmpty)
  }

  func testSingleBindingRetryEnablesOnlyTheRequestedStartupConflictWithoutSaving() async throws {
    let a = record(id: "a-retry", slot: 0, name: "A", hotkeyKey: 3)
    let s = record(id: "s-retry", slot: 1, name: "S", hotkeyKey: 4)
    let registrar = ModuleFakeHotkeyRegistrar()
    registrar.failingIDs = [.direct(bindingID: s.id)]
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: a, 1: s])
    )
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    XCTAssertEqual(module.directConflictKeyCodes, [1])

    registrar.failingIDs.removeAll()
    let result = await module.retryDirectHotkey(bindingID: s.id)

    XCTAssertEqual(result, .enabled(s.id))
    XCTAssertEqual(registrar.registrations[.direct(bindingID: s.id)], s.directHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: a.id)], a.directHotkey)
    XCTAssertTrue(module.directConflictKeyCodes.isEmpty)
    XCTAssertEqual(store.saveCount, 0)
  }

  func testSingleBindingRetryKeepsConflictWhenCombinationIsStillUnavailable() async throws {
    var item = record(id: "still-conflicted", slot: 0, name: "A", hotkeyKey: 3)
    item.target.displayName = "/private-fixture/secret-target.app"
    let registrar = ModuleFakeHotkeyRegistrar()
    registrar.failingIDs = [.direct(bindingID: item.id)]
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
      )
    )
    try await module.start()

    let result = await module.retryDirectHotkey(bindingID: item.id)

    XCTAssertEqual(result, .stillConflicted(item.id))
    XCTAssertEqual(module.directConflictKeyCodes, [0])
    XCTAssertNil(registrar.registrations[.direct(bindingID: item.id)])
    XCTAssertFalse(module.statusText.contains("/private-fixture"))
    XCTAssertFalse(module.errorMessage?.contains("/private-fixture") == true)
    XCTAssertTrue(module.errorMessage?.contains("网页") == true)
  }

  func testCancelEditingChangesNeitherStoreNorRuntime() async throws {
    let original = LauncherConfiguration(bindings: [0: record(id: "a", slot: 0, name: "A", hotkeyKey: 3)])
    let store = MemoryConfigurationStore(configuration: original)
    let module = makeModule(store: store)
    try await module.start()

    module.beginEditing()
    module.clearBinding(for: 0)
    XCTAssertNil(module.binding(for: 0))
    module.cancelEditing()

    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.configuration, original)
    XCTAssertEqual(store.saveCount, 0)
  }

  func testClosingSingleBindingEditorDiscardsItsDraftImmediately() async throws {
    let store = MemoryConfigurationStore()
    let module = makeModule(store: store)
    try await module.start()

    module.requestBinding(for: 0)
    module.bindWebURL("https://single.example", to: 0)
    XCTAssertTrue(module.isSingleBindingEditing)
    XCTAssertNotNil(module.binding(for: 0))

    module.closeBindingEditor()

    XCTAssertFalse(module.isEditing)
    XCTAssertFalse(module.isSingleBindingEditing)
    XCTAssertNil(module.binding(for: 0))
    XCTAssertEqual(module.currentConfiguration, LauncherConfiguration())
    XCTAssertEqual(store.saveCount, 0)
  }

  func testEmptyConfigurationPresentationKeepsMainGridWithoutPreselectingSlot() async throws {
    let store = MemoryConfigurationStore()
    let presenter = RecordingPanelPresenter()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      panelPresenterFactory: { _ in presenter }
    )
    try await module.start()

    module.presentPanel(invokedByHotkey: true)

    XCTAssertTrue(presenter.isVisible)
    XCTAssertEqual(presenter.showCount, 1)
    XCTAssertNil(module.bindingRequestKeyCode)
    XCTAssertFalse(module.isEditing)
    XCTAssertFalse(module.isSingleBindingEditing)
    XCTAssertEqual(module.currentConfiguration, LauncherConfiguration())
    XCTAssertEqual(store.saveCount, 0)
    await module.stop()
  }

  func testUserCanChooseAnyNonQSlotAfterGridPresentation() async throws {
    let store = MemoryConfigurationStore()
    let presenter = RecordingPanelPresenter()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      panelPresenterFactory: { _ in presenter }
    )
    try await module.start()

    module.presentPanel(invokedByHotkey: true)
    XCTAssertNil(module.bindingRequestKeyCode)
    XCTAssertFalse(module.isEditing)

    XCTAssertTrue(presenter.isVisible)
    XCTAssertEqual(presenter.showCount, 1)
    let chosenKeyCode: UInt16 = 0

    module.requestBinding(for: chosenKeyCode)

    XCTAssertEqual(module.bindingRequestKeyCode, chosenKeyCode)
    XCTAssertNotEqual(module.bindingRequestKeyCode, PhysicalKeyCode.q)
    XCTAssertTrue(module.isEditing)
    XCTAssertTrue(module.isSingleBindingEditing)
    XCTAssertEqual(module.currentConfiguration, LauncherConfiguration())
    XCTAssertEqual(store.saveCount, 0)
    await module.stop()
  }

  func testConfiguredPresentationAlsoKeepsMainGridWithoutPreselectingSlot() async throws {
    let item = record(
      id: "configured-panel",
      slot: 0,
      name: "Configured",
      hotkeyKey: 3
    )
    let presenter = RecordingPanelPresenter()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(bindings: [0: item])
      ),
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      panelPresenterFactory: { _ in presenter }
    )
    try await module.start()

    module.presentPanel(invokedByHotkey: true)

    XCTAssertTrue(presenter.isVisible)
    XCTAssertEqual(presenter.showCount, 1)
    XCTAssertNil(module.bindingRequestKeyCode)
    XCTAssertFalse(module.isEditing)
    XCTAssertFalse(module.isSingleBindingEditing)
    await module.stop()
  }

  func testBindingEditorSaveDoesNotRequireAnActiveRecorderSession() async throws {
    let module = makeModule()
    try await module.start()
    module.requestBinding(for: PhysicalKeyCode.q)
    module.bindWebURL("https://panel-only.example", to: PhysicalKeyCode.q)

    XCTAssertFalse(module.isHotkeyRecorderReady)
    XCTAssertTrue(BindingEditorView(module: module, keyCode: PhysicalKeyCode.q).canSave)

    module.setDraftDirectHotkey(
      HotkeyDefinition(keyCode: 13, modifiers: [.command, .option]),
      for: PhysicalKeyCode.q
    )
    XCTAssertFalse(module.isHotkeyRecorderReady)
    XCTAssertTrue(BindingEditorView(module: module, keyCode: PhysicalKeyCode.q).canSave)
  }

  func testSingleBindingTransactionRejectsCrossSlotAndGlobalDraftMutations() async throws {
    let first = record(id: "single-first", slot: 0, name: "First", hotkeyKey: 3)
    let second = record(id: "single-second", slot: 1, name: "Second", hotkeyKey: 4)
    let original = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: first, 1: second]
    )
    let store = MemoryConfigurationStore(configuration: original)
    let module = makeModule(store: store)
    try await module.start()

    module.requestBinding(for: 0)
    module.bindWebURL("https://updated-first.example", to: 0)
    module.requestBinding(for: 1)
    module.bindWebURL("https://forbidden-second.example", to: 1)
    module.setDraftDirectHotkey(nil, for: 1)
    module.setDraftPanelHotkey(
      HotkeyDefinition(keyCode: 5, modifiers: [.command, .option])
    )
    module.setDraftDirectModeEnabled(false)
    module.moveBinding(from: 0, to: 1)
    module.resetDraftToDefaults()

    XCTAssertEqual(module.bindingRequestKeyCode, 0)
    XCTAssertEqual(module.displayedConfiguration.bindings[1], second)
    XCTAssertEqual(module.displayedConfiguration.panelHotkey, original.panelHotkey)
    XCTAssertTrue(module.displayedConfiguration.directModeEnabled)

    let result = await module.commitEditingWithResult()

    guard case .committed = result else {
      return XCTFail("Expected the in-scope slot edit to commit")
    }
    XCTAssertEqual(module.currentConfiguration.bindings[0]?.target.displayName, "updated-first.example")
    XCTAssertEqual(module.currentConfiguration.bindings[1], second)
    XCTAssertEqual(module.currentConfiguration.panelHotkey, original.panelHotkey)
    XCTAssertTrue(module.currentConfiguration.directModeEnabled)
    await module.stop()
  }

  func testStructuredSingleBindingCommitReportsRevisionAndEnabledIdentity() async throws {
    let store = MemoryConfigurationStore()
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    module.requestBinding(for: 0)
    module.bindWebURL("https://single.example", to: 0)
    let id = try XCTUnwrap(module.bindingRecord(for: 0)?.id)
    let hotkey = HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    module.setDraftDirectHotkey(hotkey, for: 0)
    let result = await module.commitEditingWithResult()

    XCTAssertEqual(result, .committed(configurationRevision: 2, enabled: [id]))
    XCTAssertEqual(store.configuration.bindings[0]?.directHotkey, hotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: id)], hotkey)
    XCTAssertFalse(module.isEditing)
  }

  func testPublicHostContractSnapshotAndRevisionAwareCommitUseOnlyPublicSurface() async throws {
    let store = MemoryConfigurationStore()
    let concrete = makeModule(store: store)
    let controller: any ShortcutLauncherControlling = concrete
    try await controller.start()

    XCTAssertEqual(controller.snapshot.lifecycleState, .running)
    XCTAssertEqual(controller.snapshot.configurationRevision, 1)
    XCTAssertEqual(controller.snapshot.bindings.count, KeySlotCatalog.all.count)
    XCTAssertTrue(controller.snapshot.directHotkeysPaused)

    var candidate = LauncherConfiguration()
    candidate.bindings[0] = BindingRecord(
      id: BindingID(rawValue: "host-binding"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .web,
        displayName: "Example",
        lastKnownURL: try XCTUnwrap(URL(string: "https://example.com/private?token=hidden"))
      )
    )
    let result = await controller.commit(LauncherCommitRequest(
      expectedConfigurationRevision: 1,
      candidateConfiguration: candidate
    ))

    XCTAssertEqual(result, .committed(configurationRevision: 2, enabled: []))
    XCTAssertEqual(controller.snapshot.configurationRevision, 2)
    XCTAssertEqual(controller.snapshot.bindings.first { $0.slotKeyCode == 0 }?.displayName, "Example")

    let stale = await controller.commit(LauncherCommitRequest(
      expectedConfigurationRevision: 1,
      candidateConfiguration: LauncherConfiguration()
    ))
    XCTAssertEqual(stale, .rejected(reason: .staleRevision))
  }

  func testPublicResultsAndRetryUsePrivacySafeIDForLegacyPathIdentifier() async throws {
    let privateID = BindingID(rawValue: "file:///private-fixture/Documents/private-target")
    let item = BindingRecord(
      id: privateID,
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .web,
        displayName: "Private target",
        lastKnownURL: try XCTUnwrap(URL(string: "https://example.com"))
      ),
      directHotkey: HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    )
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(
          directModeEnabled: true,
          bindings: [PhysicalKeyCode.q: item]
        )
      ),
      opener: opener
    )
    try await module.start()

    let publicID = try XCTUnwrap(
      module.snapshot.bindings.first { $0.slotKeyCode == PhysicalKeyCode.q }?.bindingID
    )
    XCTAssertEqual(publicID, privateID.hostSafeProjection)
    XCTAssertNotEqual(publicID, privateID)
    XCTAssertEqual(module.registrationLedgerSnapshot.registeredBindingIDs, [publicID])
    XCTAssertFalse(
      String(reflecting: module.registrationLedgerSnapshot).contains("/private-fixture")
    )
    let registrationCount = registrar.registerCount

    let retryResult = await module.retryDirectHotkey(bindingID: publicID)
    XCTAssertEqual(retryResult, .enabled(publicID))
    XCTAssertEqual(registrar.registerCount, registrationCount)
    let executionResult = await module.executeWithResult(
      bindingID: publicID,
      source: .directHotkey
    )
    XCTAssertEqual(executionResult, .accepted(publicID))
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Private target"])

    module.requestBinding(for: PhysicalKeyCode.q)
    module.bindWebURL("https://updated.example", to: PhysicalKeyCode.q)
    let commitResult = await module.commitEditingWithResult()
    XCTAssertEqual(
      commitResult,
      .committed(configurationRevision: 2, enabled: [publicID])
    )
    XCTAssertFalse(String(reflecting: commitResult).contains("/private-fixture"))
  }

  func testPublicCommitDistinguishesPanelConflictAndNamesBothDuplicateBindings() async throws {
    let module = makeModule()
    let controller: any ShortcutLauncherControlling = module
    try await controller.start()
    let revision = controller.snapshot.configurationRevision

    var panelConflict = record(id: "panel-conflict", slot: 0, name: "Panel", hotkeyKey: 3)
    panelConflict.directHotkey = .defaultPanel
    let panelResult = await controller.commit(LauncherCommitRequest(
      expectedConfigurationRevision: revision,
      candidateConfiguration: LauncherConfiguration(
        directModeEnabled: true,
        bindings: [0: panelConflict]
      )
    ))
    XCTAssertEqual(panelResult, .validationFailed([
      LauncherIssue(
        code: .panelHotkeyConflict,
        bindingID: panelConflict.id,
        combination: .defaultPanel
      )
    ]))

    let duplicate = HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    var first = record(id: "duplicate-a", slot: 0, name: "First", hotkeyKey: 3)
    var second = record(id: "duplicate-b", slot: 1, name: "Second", hotkeyKey: 4)
    first.directHotkey = duplicate
    second.directHotkey = duplicate
    let duplicateResult = await controller.commit(LauncherCommitRequest(
      expectedConfigurationRevision: revision,
      candidateConfiguration: LauncherConfiguration(
        directModeEnabled: true,
        bindings: [0: first, 1: second]
      )
    ))
    XCTAssertEqual(duplicateResult, .validationFailed([
      LauncherIssue(
        code: .duplicateHotkey,
        bindingID: first.id,
        relatedBindingID: second.id,
        combination: duplicate
      )
    ]))
    await controller.stop()
  }

  func testCommitPersistsMultipleIndependentHotkeysOnce() async throws {
    let store = MemoryConfigurationStore()
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    module.beginEditing()
    module.bindWebURL("https://a.example", to: 0)
    module.bindWebURL("https://s.example", to: 1)
    module.setDraftDirectHotkey(HotkeyDefinition(keyCode: 3, modifiers: [.command, .option]), for: 0)
    module.setDraftDirectHotkey(HotkeyDefinition(keyCode: 4, modifiers: [.command, .shift]), for: 1)
    XCTAssertTrue(module.directModeEnabled)
    await module.commitEditing()

    XCTAssertFalse(module.isEditing)
    XCTAssertEqual(store.saveCount, 1)
    XCTAssertTrue(store.configuration.directModeEnabled)
    XCTAssertEqual(store.configuration.bindings[0]?.directHotkey?.keyCode, 3)
    XCTAssertEqual(store.configuration.bindings[1]?.directHotkey?.keyCode, 4)
  }

  func testSettingDirectHotkeyAutomaticallyEnablesModeAndRegistersOnCommit() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "wechat"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .application,
        displayName: "微信",
        lastKnownURL: URL(fileURLWithPath: "/Applications/WeChat.app")
      )
    )
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(
        directModeEnabled: false,
        bindings: [PhysicalKeyCode.q: item]
      )
    )
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(registrar: registrar, store: store, opener: opener)
    try await module.start()

    let hotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    module.beginEditing()
    module.setDraftDirectHotkey(hotkey, for: PhysicalKeyCode.q)

    XCTAssertTrue(module.directModeEnabled)
    XCTAssertTrue(module.hasPendingDirectChanges)
    XCTAssertEqual(module.directHotkey(for: PhysicalKeyCode.q), hotkey)

    await module.commitEditing()

    XCTAssertFalse(module.isEditing)
    XCTAssertTrue(store.configuration.directModeEnabled)
    XCTAssertEqual(store.configuration.bindings[PhysicalKeyCode.q]?.directHotkey, hotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], hotkey)

    registrar.trigger(.direct(bindingID: item.id))
    await Task.yield()
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["微信"])
  }

  func testDraftMutationsAndCancelAreIgnoredWhileCommitIsSuspended() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "wechat-suspended"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .application,
        displayName: "微信",
        lastKnownURL: URL(fileURLWithPath: "/Applications/WeChat.app")
      )
    )
    let original = LauncherConfiguration(bindings: [PhysicalKeyCode.q: item])
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let hotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    module.beginEditing()
    module.setDraftDirectHotkey(hotkey, for: PhysicalKeyCode.q)
    let expectedDraft = module.displayedConfiguration
    registrar.hotkeyToSuspendOnce = hotkey

    let commitTask = Task { @MainActor in await module.commitEditing() }
    for _ in 0..<100 where !registrar.isRegistrationSuspended { await Task.yield() }
    XCTAssertTrue(registrar.isRegistrationSuspended)
    XCTAssertTrue(module.isCommitting)

    module.cancelEditing()
    module.clearBinding(for: PhysicalKeyCode.q)
    module.setDraftDirectHotkey(
      HotkeyDefinition(keyCode: 4, modifiers: [.command, .shift]),
      for: PhysicalKeyCode.q
    )
    XCTAssertEqual(module.displayedConfiguration, expectedDraft)
    XCTAssertTrue(module.isEditing)

    registrar.resumeSuspendedRegistration()
    await commitTask.value

    XCTAssertFalse(module.isCommitting)
    XCTAssertFalse(module.isEditing)
    XCTAssertEqual(module.currentConfiguration, expectedDraft)
    XCTAssertEqual(store.configuration, expectedDraft)
    XCTAssertEqual(store.saveCount, 1)
  }

  func testSuspendedSaveSuppressesCandidateRouteButKeepsUnchangedCommittedRouteWorking() async throws {
    let committed = record(id: "committed-route", slot: 0, name: "Committed", hotkeyKey: 3)
    let candidateOnly = record(id: "candidate-route", slot: 1, name: "Candidate", hotkeyKey: 4)
    let original = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: committed]
    )
    var candidate = original
    candidate.bindings[1] = candidateOnly

    let repository = SuspendedSaveConfigurationRepository(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: opener,
      ownerLease: HotkeyOwnerLease(),
      uiPreferencesStore: MemoryLauncherUIPreferencesStore(),
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: NoopWebsiteIconProvider()
    )
    try await module.start()

    let commitTask = Task { @MainActor in
      await module.commit(LauncherCommitRequest(
        expectedConfigurationRevision: module.configurationRevision,
        candidateConfiguration: candidate
      ))
    }
    await repository.waitUntilSaveStarts()

    XCTAssertTrue(registrar.trigger(hotkey: try XCTUnwrap(candidateOnly.directHotkey)))
    await Task.yield()
    XCTAssertTrue(opener.openedTargets.isEmpty)

    XCTAssertTrue(registrar.trigger(hotkey: try XCTUnwrap(committed.directHotkey)))
    for _ in 0..<3 { await Task.yield() }
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Committed"])
    XCTAssertEqual(module.currentConfiguration, original)

    await repository.resumeSave()
    let result = await commitTask.value
    XCTAssertEqual(
      result,
      .committed(
        configurationRevision: 2,
        enabled: [candidateOnly.id, committed.id].sorted { $0.rawValue < $1.rawValue }
      )
    )

    XCTAssertTrue(registrar.trigger(hotkey: try XCTUnwrap(candidateOnly.directHotkey)))
    for _ in 0..<3 { await Task.yield() }
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Committed", "Candidate"])
  }

  func testAcceptedDirectCallbackKeepsOldTargetWhenExecutionRunsAfterCommit() async throws {
    let committed = record(id: "frozen-direct-route", slot: 0, name: "Old", hotkeyKey: 3)
    let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: committed])
    var replacement = committed
    replacement.target = LaunchTarget(
      kind: .web,
      displayName: "New",
      lastKnownURL: try XCTUnwrap(URL(string: "https://new.example"))
    )
    var candidate = original
    candidate.bindings[0] = replacement

    let repository = SuspendedSaveConfigurationRepository(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let executionGate = MainActorAsyncGate()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: opener,
      ownerLease: HotkeyOwnerLease()
    )
    module.directExecutionBarrierForTesting = { await executionGate.wait() }
    try await module.start()

    let commitTask = Task { @MainActor in
      await module.commit(LauncherCommitRequest(
        expectedConfigurationRevision: module.configurationRevision,
        candidateConfiguration: candidate
      ))
    }
    await repository.waitUntilSaveStarts()

    XCTAssertTrue(registrar.trigger(hotkey: try XCTUnwrap(committed.directHotkey)))
    await repository.resumeSave()
    guard case .committed = await commitTask.value else {
      return XCTFail("Expected replacement configuration to commit")
    }
    XCTAssertEqual(module.currentConfiguration, candidate)
    XCTAssertTrue(opener.openedTargets.isEmpty)

    executionGate.open()
    for _ in 0..<20 where opener.openedTargets.isEmpty { await Task.yield() }
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Old"])
  }

  func testAcceptedDirectCallbackCannotExecuteAcrossStopAndRestart() async throws {
    let item = record(id: "lifecycle-frozen-route", slot: 0, name: "Old", hotkeyKey: 3)
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let executionGate = MainActorAsyncGate()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
      ),
      opener: opener
    )
    module.directExecutionBarrierForTesting = { await executionGate.wait() }
    try await module.start()

    XCTAssertTrue(registrar.trigger(hotkey: try XCTUnwrap(item.directHotkey)))
    await Task.yield()
    await module.stop()
    try await module.start()

    executionGate.open()
    for _ in 0..<20 { await Task.yield() }

    XCTAssertTrue(opener.openedTargets.isEmpty)
  }

  func testPreparedCommitFailureRestoresPrimaryAndBackupToOldConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shortcut-launcher-module-rollback-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(storageDirectory: directory)
    let committed = record(id: "rollback-route", slot: 0, name: "Committed", hotkeyKey: 3)
    let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: committed])
    try await repository.save(original)

    var replacement = committed
    replacement.target = LaunchTarget(
      kind: .web,
      displayName: "Rejected",
      lastKnownURL: try XCTUnwrap(URL(string: "https://rejected.example"))
    )
    var candidate = original
    candidate.bindings[0] = replacement

    let registrar = ModuleFakeHotkeyRegistrar()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease()
    )
    try await module.start()
    registrar.shouldFailPreparedCommitOnce = true

    let result = await module.commit(LauncherCommitRequest(
      expectedConfigurationRevision: module.configurationRevision,
      candidateConfiguration: candidate
    ))

    if case .registrationFailed = result {
      // Expected: the prepared route publication rejected the candidate.
    } else {
      XCTFail("Expected a structured registration failure, got \(result)")
    }
    XCTAssertEqual(module.currentConfiguration, original)
    let decoder = JSONDecoder()
    XCTAssertEqual(
      try decoder.decode(
        LauncherConfiguration.self,
        from: Data(contentsOf: repository.configurationURL)
      ),
      original
    )
    XCTAssertEqual(
      try decoder.decode(
        LauncherConfiguration.self,
        from: Data(contentsOf: repository.backupURL)
      ),
      original
    )
  }

  func testPostRenameSaveFailureCompensatesDiskBeforeReportingFailure() async throws {
    for failure in [ModuleDurabilityFailure.directorySync, .directoryClose] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "shortcut-launcher-post-rename-\(UUID().uuidString)",
        isDirectory: true
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      let fileOperations = ArmableConfigurationFileOperations()
      let repository = ConfigurationRepository(
        backend: ConfigurationFileBackend(
          storageDirectory: directory,
          fileOperations: fileOperations
        )
      )
      let committed = record(
        id: "post-rename-\(failure)",
        slot: 0,
        name: "Committed",
        hotkeyKey: 3
      )
      let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: committed])
      try await repository.save(original)

      var replacement = committed
      replacement.target = LaunchTarget(
        kind: .web,
        displayName: "Candidate",
        lastKnownURL: try XCTUnwrap(URL(string: "https://candidate.example"))
      )
      var candidate = original
      candidate.bindings[0] = replacement

      let registrar = ModuleFakeHotkeyRegistrar()
      let module = ShortcutLauncherModule(
        registrar: registrar,
        repository: repository,
        bookmarkResolver: PassthroughBookmarkResolver(),
        opener: RecordingWorkspaceOpener(),
        ownerLease: HotkeyOwnerLease()
      )
      try await module.start()
      // Saving over an existing primary first publishes its backup, then its
      // candidate primary. Fail the second directory durability operation,
      // after the candidate rename has already happened.
      fileOperations.arm(failure, occurrence: 2)

      let result = await module.commit(LauncherCommitRequest(
        expectedConfigurationRevision: module.configurationRevision,
        candidateConfiguration: candidate
      ))

      XCTAssertEqual(result, .persistenceFailed(code: .writeFailed))
      XCTAssertEqual(module.currentConfiguration, original)
      XCTAssertFalse(module.snapshot.issueCodes.contains(.configurationRollbackFailed))
      let decoder = JSONDecoder()
      XCTAssertEqual(
        try decoder.decode(
          LauncherConfiguration.self,
          from: Data(contentsOf: repository.configurationURL)
        ),
        original
      )
      XCTAssertEqual(
        try decoder.decode(
          LauncherConfiguration.self,
          from: Data(contentsOf: repository.backupURL)
        ),
        original
      )

      await module.stop()
      let restartedOpener = RecordingWorkspaceOpener()
      let restarted = ShortcutLauncherModule(
        registrar: ModuleFakeHotkeyRegistrar(),
        repository: repository,
        bookmarkResolver: PassthroughBookmarkResolver(),
        opener: restartedOpener,
        ownerLease: HotkeyOwnerLease()
      )
      try await restarted.start()
      await restarted.execute(bindingID: committed.id, source: .directHotkey)
      XCTAssertEqual(restartedOpener.openedTargets.map(\.displayName), ["Committed"])
      await restarted.stop()
    }
  }

  func testPreparedCommitAndPersistenceRollbackFailureReportDiskTruthfully() async throws {
    let committed = record(id: "rollback-truth", slot: 0, name: "Committed", hotkeyKey: 3)
    let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: committed])
    var replacement = committed
    replacement.target = LaunchTarget(
      kind: .web,
      displayName: "Candidate",
      lastKnownURL: try XCTUnwrap(URL(string: "https://candidate.example"))
    )
    var candidate = original
    candidate.bindings[0] = replacement

    let repository = FailingRestoreConfigurationRepository(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease()
    )
    try await module.start()
    registrar.shouldFailPreparedCommitOnce = true

    let result = await module.commit(LauncherCommitRequest(
      expectedConfigurationRevision: module.configurationRevision,
      candidateConfiguration: candidate
    ))

    XCTAssertEqual(result, .persistenceFailed(code: .rollbackFailed))
    XCTAssertEqual(module.currentConfiguration, original)
    let persistedConfiguration = await repository.persistedConfiguration()
    XCTAssertEqual(persistedConfiguration, candidate)
    XCTAssertTrue(module.statusText.contains("磁盘配置未能回滚"))
    XCTAssertFalse(module.statusText.contains("旧配置已保留"))
    XCTAssertTrue(module.snapshot.issueCodes.contains(.configurationRollbackFailed))
  }

  func testLegacyFacadeUsesExactRawIDWhenItEqualsAnotherBindingsPublicAlias() async throws {
    let privateID = BindingID(rawValue: "file:///private-fixture/first")
    let firstPublicID = privateID.hostSafeProjection
    let namespaceLookalikeID = BindingID(rawValue: firstPublicID.rawValue)
    let first = BindingRecord(
      id: privateID,
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .web,
        displayName: "First",
        lastKnownURL: try XCTUnwrap(URL(string: "https://first.example"))
      )
    )
    let second = BindingRecord(
      id: namespaceLookalikeID,
      physicalKeyCode: 1,
      target: LaunchTarget(
        kind: .web,
        displayName: "Second",
        lastKnownURL: try XCTUnwrap(URL(string: "https://second.example"))
      )
    )
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(bindings: [0: first, 1: second])
      ),
      opener: opener
    )
    try await module.start()

    await module.execute(bindingID: namespaceLookalikeID, source: .directHotkey)
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Second"])

    let firstResult = await module.executeWithResult(
      bindingID: firstPublicID,
      source: .directHotkey
    )
    XCTAssertEqual(firstResult, .accepted(firstPublicID))

    let secondPublicID = namespaceLookalikeID.hostSafeProjection
    let secondResult = await module.executeWithResult(
      bindingID: secondPublicID,
      source: .directHotkey
    )
    XCTAssertEqual(secondResult, .accepted(secondPublicID))
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Second", "First", "Second"])
  }

  func testCancelledCommitStillRestoresPrimaryAndBackupAfterPreparedRouteFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shortcut-launcher-cancelled-rollback-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(storageDirectory: directory)
    let committed = record(id: "cancelled-rollback", slot: 0, name: "Committed", hotkeyKey: 3)
    let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: committed])
    try await repository.save(original)

    var replacement = committed
    replacement.target = LaunchTarget(
      kind: .web,
      displayName: "Rejected",
      lastKnownURL: try XCTUnwrap(URL(string: "https://rejected.example"))
    )
    var candidate = original
    candidate.bindings[0] = replacement

    let registrar = ModuleFakeHotkeyRegistrar()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease()
    )
    try await module.start()
    registrar.shouldSuspendAndFailPreparedCommitOnce = true

    let commitTask = Task { @MainActor in
      await module.commit(LauncherCommitRequest(
        expectedConfigurationRevision: module.configurationRevision,
        candidateConfiguration: candidate
      ))
    }
    while !registrar.isPreparedCommitSuspended { await Task.yield() }
    commitTask.cancel()
    registrar.resumePreparedCommitWithFailure()
    _ = await commitTask.value

    let decoder = JSONDecoder()
    XCTAssertEqual(
      try decoder.decode(
        LauncherConfiguration.self,
        from: Data(contentsOf: repository.configurationURL)
      ),
      original
    )
    XCTAssertEqual(
      try decoder.decode(
        LauncherConfiguration.self,
        from: Data(contentsOf: repository.backupURL)
      ),
      original
    )
    XCTAssertEqual(module.currentConfiguration, original)
  }

  func testFailedSuspendedSaveNeverExecutesReplacementRouteAndRestoresOldRoute() async throws {
    let oldHotkey = HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    let newHotkey = HotkeyDefinition(keyCode: 4, modifiers: [.command, .shift])
    var committed = record(id: "replaced-route", slot: 0, name: "Committed", hotkeyKey: 3)
    committed.directHotkey = oldHotkey
    let original = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: committed]
    )
    var replacement = committed
    replacement.target = LaunchTarget(
      kind: .web,
      displayName: "Unpersisted",
      lastKnownURL: try XCTUnwrap(URL(string: "https://unpersisted.example"))
    )
    replacement.directHotkey = newHotkey
    var candidate = original
    candidate.bindings[0] = replacement

    let repository = SuspendedSaveConfigurationRepository(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: opener,
      ownerLease: HotkeyOwnerLease()
    )
    try await module.start()

    let commitTask = Task { @MainActor in
      await module.commit(LauncherCommitRequest(
        expectedConfigurationRevision: module.configurationRevision,
        candidateConfiguration: candidate
      ))
    }
    await repository.waitUntilSaveStarts()

    XCTAssertTrue(registrar.trigger(hotkey: newHotkey))
    XCTAssertTrue(registrar.trigger(hotkey: oldHotkey))
    for _ in 0..<3 { await Task.yield() }
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Committed"])
    XCTAssertEqual(module.currentConfiguration, original)

    await repository.failSave()
    let result = await commitTask.value
    XCTAssertEqual(result, .persistenceFailed(code: .writeFailed))
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: committed.id)], oldHotkey)

    XCTAssertTrue(registrar.trigger(hotkey: oldHotkey))
    XCTAssertFalse(registrar.trigger(hotkey: newHotkey))
    for _ in 0..<3 { await Task.yield() }
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Committed", "Committed"])
  }

  func testPanelToggleAndDismissCannotDisplaceEditorDuringSuspendedSaveFailure() async throws {
    let originalRecord = record(id: "panel-commit-editor", slot: 0, name: "Original", hotkeyKey: 3)
    let original = LauncherConfiguration(bindings: [0: originalRecord])
    let repository = SuspendedSaveConfigurationRepository(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let presenter = RecordingPanelPresenter()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      panelPresenterFactory: { _ in presenter }
    )
    try await module.start()
    module.presentPanel()
    module.requestBinding(for: 0)
    module.bindWebURL("https://edited.example", to: 0)

    let commitTask = Task { @MainActor in
      await module.commitEditingWithResult()
    }
    await repository.waitUntilSaveStarts()

    registrar.trigger(.panel)
    module.dismissPanel()
    await Task.yield()

    XCTAssertTrue(presenter.isVisible)
    XCTAssertEqual(presenter.dismissCount, 0)
    XCTAssertEqual(module.bindingRequestKeyCode, 0)
    XCTAssertTrue(module.isSingleBindingEditing)

    await repository.failSave()
    let commitResult = await commitTask.value
    XCTAssertEqual(
      commitResult,
      .persistenceFailed(code: .writeFailed)
    )
    XCTAssertEqual(module.bindingRequestKeyCode, 0)
    XCTAssertTrue(module.isSingleBindingEditing)
    XCTAssertEqual(module.binding(for: 0)?.displayName, "edited.example")
    await module.stop()
  }

  func testStopWaitsForSuspendedCommitThenUnregistersEveryHotkey() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "wechat-stop-during-commit"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .application,
        displayName: "微信",
        lastKnownURL: URL(fileURLWithPath: "/Applications/WeChat.app")
      )
    )
    let original = LauncherConfiguration(bindings: [PhysicalKeyCode.q: item])
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let hotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    module.beginEditing()
    module.setDraftDirectHotkey(hotkey, for: PhysicalKeyCode.q)
    let committedConfiguration = module.displayedConfiguration
    registrar.hotkeyToSuspendOnce = hotkey

    let commitTask = Task { @MainActor in await module.commitEditing() }
    for _ in 0..<100 where !registrar.isRegistrationSuspended { await Task.yield() }
    XCTAssertTrue(registrar.isRegistrationSuspended)
    XCTAssertTrue(module.isCommitting)

    let stopCompletion = AsyncCompletionProbe()
    let stopTask = Task { @MainActor in
      await module.stop()
      stopCompletion.didFinish = true
    }
    for _ in 0..<100
    where module.statusText != "正在完成当前保存，随后暂停所有快捷键。" {
      await Task.yield()
    }

    XCTAssertEqual(module.statusText, "正在完成当前保存，随后暂停所有快捷键。")
    XCTAssertFalse(stopCompletion.didFinish)
    XCTAssertEqual(registrar.unregisterAllCount, 0)
    XCTAssertEqual(registrar.registrations, [.panel: original.panelHotkey])

    registrar.resumeSuspendedRegistration()
    await commitTask.value
    await stopTask.value

    XCTAssertTrue(stopCompletion.didFinish)
    XCTAssertFalse(module.isCommitting)
    XCTAssertEqual(module.currentConfiguration, committedConfiguration)
    XCTAssertEqual(store.configuration, committedConfiguration)
    XCTAssertEqual(store.saveCount, 1)
    XCTAssertEqual(registrar.unregisterAllCount, 1)
    XCTAssertTrue(registrar.registrations.isEmpty)
    XCTAssertEqual(module.statusText, "已停止，快捷键已释放。")
  }

  func testStartWaitsForSuspendedStopThenRestoresPanelAndDirectHotkeys() async throws {
    let item = record(
      id: "wechat-restart-during-stop",
      slot: PhysicalKeyCode.q,
      name: "WeChat",
      hotkeyKey: 3
    )
    let configuration = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [PhysicalKeyCode.q: item]
    )
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(configuration: configuration)
    )
    try await module.start()
    XCTAssertEqual(registrar.registrations.count, 2)

    registrar.shouldSuspendUnregisterAllOnce = true
    let stopCompletion = AsyncCompletionProbe()
    let stopTask = Task { @MainActor in
      await module.stop()
      stopCompletion.didFinish = true
    }
    for _ in 0..<100 where !registrar.isUnregisterAllSuspended { await Task.yield() }
    XCTAssertTrue(registrar.isUnregisterAllSuspended)

    let startCompletion = AsyncCompletionProbe()
    let startTask = Task { @MainActor in
      try await module.start()
      startCompletion.didFinish = true
    }
    for _ in 0..<10 { await Task.yield() }

    XCTAssertFalse(stopCompletion.didFinish)
    XCTAssertFalse(startCompletion.didFinish)
    XCTAssertEqual(registrar.registerCount, 2)
    XCTAssertEqual(registrar.registrations.count, 2)

    registrar.resumeSuspendedUnregisterAll()
    await stopTask.value
    try await startTask.value

    XCTAssertTrue(stopCompletion.didFinish)
    XCTAssertTrue(startCompletion.didFinish)
    XCTAssertEqual(registrar.unregisterAllCount, 1)
    XCTAssertEqual(registrar.registerCount, 4)
    XCTAssertEqual(registrar.registrations[.panel], configuration.panelHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], item.directHotkey)
    XCTAssertEqual(registrar.registrations.count, 2)
    XCTAssertTrue(module.statusText.hasPrefix("已启动"))
  }

  func testLifecycleRequestsCompleteInFIFOOrderAfterSuspendedStop() async throws {
    let item = record(
      id: "wechat-fifo-lifecycle",
      slot: PhysicalKeyCode.q,
      name: "WeChat",
      hotkeyKey: 3
    )
    let configuration = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [PhysicalKeyCode.q: item]
    )
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(configuration: configuration)
    )
    try await module.start()

    let order = LifecycleRequestOrderRecorder()
    registrar.shouldSuspendUnregisterAllOnce = true
    let firstStop = Task { @MainActor in
      order.requested.append("stop-0")
      await module.stop()
      order.completed.append("stop-0")
    }
    for _ in 0..<100 where !registrar.isUnregisterAllSuspended { await Task.yield() }
    XCTAssertTrue(registrar.isUnregisterAllSuspended)

    let firstStart = Task { @MainActor in
      order.requested.append("start-1")
      try await module.start()
      order.completed.append("start-1")
    }
    for _ in 0..<100 where order.requested.count < 2 { await Task.yield() }

    let secondStop = Task { @MainActor in
      order.requested.append("stop-2")
      await module.stop()
      order.completed.append("stop-2")
    }
    for _ in 0..<100 where order.requested.count < 3 { await Task.yield() }

    let secondStart = Task { @MainActor in
      order.requested.append("start-3")
      try await module.start()
      order.completed.append("start-3")
    }
    for _ in 0..<100 where order.requested.count < 4 { await Task.yield() }

    XCTAssertEqual(order.requested, ["stop-0", "start-1", "stop-2", "start-3"])
    XCTAssertTrue(order.completed.isEmpty)
    XCTAssertEqual(registrar.registerCount, 2)
    XCTAssertEqual(registrar.unregisterAllCount, 1)

    registrar.resumeSuspendedUnregisterAll()
    await firstStop.value
    try await firstStart.value
    await secondStop.value
    try await secondStart.value

    XCTAssertEqual(order.completed, ["stop-0", "start-1", "stop-2", "start-3"])
    XCTAssertEqual(registrar.unregisterAllCount, 2)
    XCTAssertEqual(registrar.registerCount, 6)
    XCTAssertEqual(registrar.registrations.count, 2)
    XCTAssertEqual(registrar.registrations[.panel], configuration.panelHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], item.directHotkey)
    XCTAssertTrue(module.statusText.hasPrefix("已启动"))
  }

  func testCommitIsRejectedWhileStopIsWaitingForUnregisterAll() async throws {
    let item = record(
      id: "wechat-commit-during-stop",
      slot: PhysicalKeyCode.q,
      name: "WeChat",
      hotkeyKey: 3
    )
    let original = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [PhysicalKeyCode.q: item]
    )
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    module.beginEditing()
    module.bindWebURL("https://updated.example", to: PhysicalKeyCode.q)
    let pendingDraft = module.displayedConfiguration
    registrar.shouldSuspendUnregisterAllOnce = true

    let stopTask = Task { @MainActor in await module.stop() }
    for _ in 0..<100 where !registrar.isUnregisterAllSuspended { await Task.yield() }
    XCTAssertTrue(registrar.isUnregisterAllSuspended)

    await module.commitEditing()

    XCTAssertEqual(module.statusText, "正在暂停快捷键；当前草稿仍保留。")
    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(module.displayedConfiguration, pendingDraft)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.configuration, original)
    XCTAssertEqual(store.saveCount, 0)

    registrar.resumeSuspendedUnregisterAll()
    await stopTask.value

    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(module.displayedConfiguration, pendingDraft)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertTrue(registrar.registrations.isEmpty)
  }

  func testStopAfterFailedSuspendedCommitPreservesTheRepairableDraft() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "wechat-failed-stop"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .application,
        displayName: "微信",
        lastKnownURL: URL(fileURLWithPath: "/Applications/WeChat.app")
      )
    )
    let original = LauncherConfiguration(bindings: [PhysicalKeyCode.q: item])
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let hotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    module.beginEditing()
    module.setDraftDirectHotkey(hotkey, for: PhysicalKeyCode.q)
    let repairableDraft = module.displayedConfiguration
    registrar.hotkeyToSuspendOnce = hotkey
    store.shouldFailSave = true

    let commitTask = Task { @MainActor in await module.commitEditing() }
    for _ in 0..<100 where !registrar.isRegistrationSuspended { await Task.yield() }
    XCTAssertTrue(registrar.isRegistrationSuspended)

    let stopTask = Task { @MainActor in await module.stop() }
    registrar.resumeSuspendedRegistration()
    await commitTask.value
    await stopTask.value

    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(module.displayedConfiguration, repairableDraft)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.configuration, original)
    XCTAssertNotNil(module.errorMessage)
    XCTAssertEqual(module.statusText, "已暂停所有快捷键；未保存草稿仍保留。")
    XCTAssertTrue(registrar.registrations.isEmpty)
  }

  func testRealJSONStorePersistsAutoEnabledDirectShortcutAcrossRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shortcut-launcher-direct-restart-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let item = BindingRecord(
      id: BindingID(rawValue: "wechat-json"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .application,
        displayName: "微信",
        lastKnownURL: URL(fileURLWithPath: "/Applications/WeChat.app")
      )
    )
    let original = LauncherConfiguration(
      directModeEnabled: false,
      bindings: [PhysicalKeyCode.q: item]
    )
    let firstStore = JSONConfigurationStore(storageDirectory: directory)
    try firstStore.save(original)
    let firstRegistrar = ModuleFakeHotkeyRegistrar()
    let firstModule = ShortcutLauncherModule(
      registrar: firstRegistrar,
      store: firstStore,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      bookmarkPolicy: .lastKnownURLOnly,
      ownerLease: HotkeyOwnerLease()
    )
    try await firstModule.start()

    let hotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    firstModule.beginEditing()
    firstModule.setDraftDirectHotkey(hotkey, for: PhysicalKeyCode.q)
    await firstModule.commitEditing()
    XCTAssertNil(firstModule.errorMessage)
    await firstModule.stop()

    let storedJSON = try String(contentsOf: firstStore.configurationURL, encoding: .utf8)
    XCTAssertTrue(storedJSON.contains("\"directModeEnabled\" : true"))
    XCTAssertTrue(storedJSON.contains("\"directHotkey\""))

    let secondStore = JSONConfigurationStore(storageDirectory: directory)
    let persisted = try secondStore.load()
    XCTAssertTrue(persisted.directModeEnabled)
    XCTAssertEqual(persisted.bindings[PhysicalKeyCode.q]?.directHotkey, hotkey)

    let secondRegistrar = ModuleFakeHotkeyRegistrar()
    let secondModule = ShortcutLauncherModule(
      registrar: secondRegistrar,
      store: secondStore,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      bookmarkPolicy: .lastKnownURLOnly,
      ownerLease: HotkeyOwnerLease()
    )
    try await secondModule.start()
    XCTAssertEqual(secondRegistrar.registrations[.panel], persisted.panelHotkey)
    XCTAssertEqual(secondRegistrar.registrations[.direct(bindingID: item.id)], hotkey)
    await secondModule.stop()
  }

  func testDirectActivationConflictRollsBackMasterSwitchAndKeepsDraft() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "wechat"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .application,
        displayName: "微信",
        lastKnownURL: URL(fileURLWithPath: "/Applications/WeChat.app")
      )
    )
    let original = LauncherConfiguration(
      directModeEnabled: false,
      bindings: [PhysicalKeyCode.q: item]
    )
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let hotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    registrar.failureBudgetByHotkey[hotkey] = 1
    module.beginEditing()
    module.setDraftDirectHotkey(hotkey, for: PhysicalKeyCode.q)
    await module.commitEditing()

    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.configuration, original)
    XCTAssertFalse(module.currentConfiguration.directModeEnabled)
    XCTAssertNil(registrar.registrations[.direct(bindingID: item.id)])
    XCTAssertTrue(module.directModeEnabled)
    XCTAssertEqual(module.directHotkey(for: PhysicalKeyCode.q), hotkey)
    XCTAssertTrue(module.errorMessage?.contains("微信") == true)
    XCTAssertTrue(module.errorMessage?.contains(hotkey.displayName) == true)
  }

  func testStoreFailureAfterDirectRegistrationRollsBackRuntimeAndEnablement() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "wechat"),
      physicalKeyCode: PhysicalKeyCode.q,
      target: LaunchTarget(
        kind: .application,
        displayName: "微信",
        lastKnownURL: URL(fileURLWithPath: "/Applications/WeChat.app")
      )
    )
    let original = LauncherConfiguration(
      directModeEnabled: false,
      bindings: [PhysicalKeyCode.q: item]
    )
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let hotkey = HotkeyDefinition(keyCode: PhysicalKeyCode.q, modifiers: .defaultDirect)
    module.beginEditing()
    module.setDraftDirectHotkey(hotkey, for: PhysicalKeyCode.q)
    store.shouldFailSave = true
    await module.commitEditing()

    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.configuration, original)
    XCTAssertNil(registrar.registrations[.direct(bindingID: item.id)])
    XCTAssertEqual(registrar.registrations[.panel], original.panelHotkey)
    XCTAssertTrue(module.directModeEnabled)
    XCTAssertEqual(module.directHotkey(for: PhysicalKeyCode.q), hotkey)
    XCTAssertNotNil(module.errorMessage)
    XCTAssertFalse(module.errorMessage?.contains("/private-fixture") == true)
    XCTAssertTrue(module.errorMessage?.contains("无法保存快捷启动配置") == true)
  }

  func testTransientRollbackFailureRebuildsTheOldRegistrationGraph() async throws {
    let item = record(id: "wechat", slot: PhysicalKeyCode.q, name: "WeChat", hotkeyKey: 3)
    let original = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [PhysicalKeyCode.q: item]
    )
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let oldHotkey = try XCTUnwrap(item.directHotkey)
    let replacement = HotkeyDefinition(keyCode: 4, modifiers: .defaultDirect)
    registrar.failureBudgetByHotkey[oldHotkey] = 1
    store.shouldFailSave = true
    module.beginEditing()
    module.setDraftDirectHotkey(replacement, for: PhysicalKeyCode.q)
    await module.commitEditing()

    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.configuration, original)
    XCTAssertEqual(registrar.registrations[.panel], original.panelHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], oldHotkey)
    XCTAssertTrue(module.directConflictKeyCodes.isEmpty)
    XCTAssertNotNil(module.errorMessage)
  }

  func testClearingOneDirectHotkeyDoesNotPauseRemainingBindings() async throws {
    let a = record(id: "a", slot: 0, name: "A", hotkeyKey: 3)
    let s = record(id: "s", slot: 1, name: "S", hotkeyKey: 4)
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: a, 1: s])
    )
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    module.beginEditing()
    module.setDraftDirectHotkey(nil, for: 0)
    XCTAssertTrue(module.directModeEnabled)
    await module.commitEditing()

    XCTAssertTrue(store.configuration.directModeEnabled)
    XCTAssertNil(store.configuration.bindings[0]?.directHotkey)
    XCTAssertNil(registrar.registrations[.direct(bindingID: a.id)])
    XCTAssertEqual(registrar.registrations[.direct(bindingID: s.id)], s.directHotkey)
  }

  func testDuplicateDraftShortcutBlocksCommitBeforeRuntimeMutation() async throws {
    let a = BindingRecord(
      id: BindingID(rawValue: "a"),
      physicalKeyCode: 0,
      target: LaunchTarget(kind: .web, displayName: "A", lastKnownURL: URL(string: "https://a.example")!)
    )
    let s = BindingRecord(
      id: BindingID(rawValue: "s"),
      physicalKeyCode: 1,
      target: LaunchTarget(kind: .web, displayName: "S", lastKnownURL: URL(string: "https://s.example")!)
    )
    let original = LauncherConfiguration(bindings: [0: a, 1: s])
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let duplicate = HotkeyDefinition(keyCode: 3, modifiers: .defaultDirect)
    module.beginEditing()
    module.setDraftDirectHotkey(duplicate, for: 0)
    module.setDraftDirectHotkey(duplicate, for: 1)

    XCTAssertNotNil(module.draftValidationMessage)
    XCTAssertFalse(module.canCommitEditing)
    await module.commitEditing()

    XCTAssertEqual(store.saveCount, 0)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(registrar.registrations, [.panel: original.panelHotkey])
    XCTAssertTrue(module.isEditing)
  }

  func testRegistrationFailureRollsBackEarlierChangesAndStore() async throws {
    let originalRecord = record(id: "a", slot: 0, name: "A", hotkeyKey: 3)
    let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: originalRecord])
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    module.beginEditing()
    module.setDraftDirectHotkey(HotkeyDefinition(keyCode: 4, modifiers: [.command, .option]), for: 0)
    module.bindWebURL("https://s.example", to: 1)
    let newHotkey = HotkeyDefinition(keyCode: 5, modifiers: [.command, .option])
    module.setDraftDirectHotkey(newHotkey, for: 1)
    registrar.failureBudgetByHotkey[newHotkey] = 1
    await module.commitEditing()

    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.configuration, original)
    XCTAssertEqual(
      registrar.registrations[.direct(bindingID: originalRecord.id)],
      originalRecord.directHotkey
    )
    XCTAssertNotNil(module.errorMessage)
  }

  func testPanelAndDirectHotkeysCanTradeCombinationsInOneTransaction() async throws {
    let direct = HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    let item = BindingRecord(
      id: BindingID(rawValue: "a"),
      physicalKeyCode: 0,
      target: LaunchTarget(kind: .web, displayName: "A", lastKnownURL: URL(string: "https://a.example")!),
      directHotkey: direct
    )
    let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
    let store = MemoryConfigurationStore(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    module.beginEditing()
    module.setDraftPanelHotkey(direct)
    module.setDraftDirectHotkey(.defaultPanel, for: 0)
    await module.commitEditing()

    XCTAssertFalse(module.isEditing)
    XCTAssertEqual(module.currentConfiguration.panelHotkey, direct)
    XCTAssertEqual(module.currentConfiguration.bindings[0]?.directHotkey, .defaultPanel)
    XCTAssertEqual(registrar.registrations[.panel], direct)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], .defaultPanel)
  }

  func testDragSwapKeepsShortcutWithBindingIdentity() async throws {
    let a = record(id: "a", slot: 0, name: "A", hotkeyKey: 3)
    let s = record(id: "s", slot: 1, name: "S", hotkeyKey: 4)
    let module = makeModule(store: MemoryConfigurationStore(configuration: LauncherConfiguration(bindings: [0: a, 1: s])))
    try await module.start()

    module.beginEditing()
    module.moveBinding(from: 0, to: 1)

    XCTAssertEqual(module.bindingRecord(for: 1)?.id, a.id)
    XCTAssertEqual(module.directHotkey(for: 1), a.directHotkey)
    XCTAssertEqual(module.bindingRecord(for: 0)?.id, s.id)
  }

  func testOneThousandDirectDispatchesAlwaysRouteToSameBinding() async throws {
    let item = record(id: "a", slot: 0, name: "A", hotkeyKey: 3)
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(
      store: MemoryConfigurationStore(configuration: LauncherConfiguration(bindings: [0: item])),
      opener: opener
    )
    try await module.start()

    for _ in 0..<1_000 {
      await module.execute(bindingID: item.id, source: .directHotkey)
    }

    XCTAssertEqual(opener.openedTargets.count, 1_000)
    XCTAssertTrue(opener.openedTargets.allSatisfy { $0.displayName == "A" })
  }

  func testConflictingPanelHotkeyDoesNotReplaceStoredShortcut() async throws {
    let registrar = ModuleFakeHotkeyRegistrar()
    let store = MemoryConfigurationStore()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    let replacement = HotkeyDefinition(keyCode: 0, modifiers: [.command, .option])
    registrar.failureBudgetByHotkey[replacement] = 1

    await module.updatePanelHotkey(replacement)

    XCTAssertEqual(module.currentConfiguration.panelHotkey, .defaultPanel)
    XCTAssertEqual(store.configuration.panelHotkey, .defaultPanel)
    XCTAssertNotNil(module.errorMessage)
  }

  func testInvalidBookmarkMarksSlotWithoutDeletingBinding() async throws {
    let target = LaunchTarget(
      kind: .file,
      displayName: "missing.txt",
      lastKnownURL: URL(fileURLWithPath: "/tmp/missing.txt"),
      bookmarkData: Data("missing".utf8)
    )
    let record = BindingRecord(id: BindingID(rawValue: "missing"), physicalKeyCode: 0, target: target)
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(bindings: [0: record]))
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: FailingBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease()
    )
    try await module.start()

    await module.executeBinding(keyCode: 0, source: .directHotkey)

    XCTAssertEqual(module.invalidKeyCodes, [0])
    XCTAssertEqual(module.binding(for: 0), target)
    XCTAssertEqual(store.configuration.bindings[0]?.target, target)
  }

  func testStructuredExecutionFailurePublishesPrivacySafeRepairPrompt() async throws {
    let target = LaunchTarget(
      kind: .file,
      displayName: "missing.txt",
      lastKnownURL: URL(fileURLWithPath: "/tmp/private/missing.txt"),
      bookmarkData: Data("missing".utf8)
    )
    let item = BindingRecord(
      id: BindingID(rawValue: "file:///private-fixture/Bindings/missing-with-feedback"),
      physicalKeyCode: 0,
      target: target
    )
    let feedbackPresenter = RecordingFeedbackPresenter()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(bindings: [0: item])
      ),
      bookmarkResolver: FailingBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      feedbackPresenter: feedbackPresenter
    )
    try await module.start()

    let result = await module.executeWithResult(bindingID: item.id, source: .directHotkey)

    let publicID = item.id.hostSafeProjection
    XCTAssertEqual(result, .targetUnavailable(publicID))
    XCTAssertEqual(module.repairPrompt?.bindingID, publicID)
    XCTAssertEqual(module.repairPrompt?.displayName, "missing.txt")
    XCTAssertEqual(module.repairPrompt?.errorCode, .targetResolutionFailed)
    XCTAssertFalse(String(describing: module.repairPrompt).contains("/tmp/private"))
    XCTAssertFalse(module.statusText.contains("/tmp/private"))
    XCTAssertNil(module.errorMessage)
    XCTAssertEqual(feedbackPresenter.presented, [module.repairPrompt!])

    module.dismissRepairPrompt()
    XCTAssertEqual(feedbackPresenter.dismissedBindingIDs, [publicID])

    _ = await module.executeWithResult(bindingID: item.id, source: .directHotkey)
    XCTAssertNotNil(module.repairPrompt)
    module.openRepairPrompt()
    XCTAssertNil(module.repairPrompt)
    XCTAssertEqual(module.quickBindingRequestKeyCode, 0)
    XCTAssertNil(module.bindingRequestKeyCode)
    XCTAssertEqual(feedbackPresenter.dismissedBindingIDs, [publicID, publicID])

    _ = await module.executeWithResult(bindingID: publicID, source: .directHotkey)
    XCTAssertNotNil(module.repairPrompt)
    await module.stop()
    XCTAssertNil(module.repairPrompt)
    XCTAssertEqual(feedbackPresenter.dismissedBindingIDs, [publicID, publicID, publicID])
  }

  func testLateFailureFromReplacedBindingCannotMarkTheNewSlotUnavailable() async throws {
    let oldTarget = LaunchTarget(
      kind: .file,
      displayName: "old.txt",
      lastKnownURL: URL(fileURLWithPath: "/tmp/private/old.txt")
    )
    let oldRecord = BindingRecord(
      id: BindingID(rawValue: "old-suspended-execution"),
      physicalKeyCode: 0,
      target: oldTarget
    )
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(bindings: [0: oldRecord])
    )
    let opener = SuspendingWorkspaceOpener()
    let feedbackPresenter = RecordingFeedbackPresenter()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: opener,
      ownerLease: HotkeyOwnerLease(),
      feedbackPresenter: feedbackPresenter
    )
    try await module.start()

    let execution = Task { @MainActor in
      await module.executeWithResult(bindingID: oldRecord.id, source: .directHotkey)
    }
    for _ in 0..<100 where !opener.isSuspended { await Task.yield() }
    XCTAssertTrue(opener.isSuspended)

    let newRecord = BindingRecord(
      id: BindingID(rawValue: "replacement-binding"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .web,
        displayName: "replacement.example",
        lastKnownURL: URL(string: "https://replacement.example")!
      )
    )
    let commitResult = await module.commit(LauncherCommitRequest(
      expectedConfigurationRevision: module.snapshot.configurationRevision,
      candidateConfiguration: LauncherConfiguration(bindings: [0: newRecord])
    ))
    guard case .committed = commitResult else {
      return XCTFail("Expected the replacement configuration to commit")
    }
    let committedStatus = module.statusText

    opener.fail(with: LauncherError.targetOpenFailed("/tmp/private/old.txt"))
    let result = await execution.value

    XCTAssertEqual(result, .targetUnavailable(oldRecord.id))
    XCTAssertEqual(module.currentConfiguration.bindings[0], newRecord)
    XCTAssertTrue(module.invalidKeyCodes.isEmpty)
    XCTAssertNil(module.repairPrompt)
    XCTAssertTrue(feedbackPresenter.presented.isEmpty)
    XCTAssertEqual(module.statusText, committedStatus)
    await module.stop()
  }

  func testRelocatingUnavailableTargetPreservesBindingIdentitySlotAndHotkey() async throws {
    let hotkey = HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    let originalTarget = LaunchTarget(
      kind: .file,
      displayName: "missing.txt",
      lastKnownURL: URL(fileURLWithPath: "/tmp/missing.txt"),
      bookmarkData: Data("missing".utf8)
    )
    let item = BindingRecord(
      id: BindingID(rawValue: "relocate-stable-id"),
      physicalKeyCode: 0,
      target: originalTarget,
      directHotkey: hotkey
    )
    let replacementURL = URL(fileURLWithPath: "/tmp/replacement.txt")
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(
        directModeEnabled: true,
        bindings: [0: item]
      )
    )
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      targetPicker: StubTargetPicker(url: replacementURL)
    )
    try await module.start()

    module.requestBinding(for: 0)
    module.chooseTarget(kind: .file, for: 0)
    let draft = try XCTUnwrap(module.bindingRecord(for: 0))
    XCTAssertEqual(draft.id, item.id)
    XCTAssertEqual(draft.physicalKeyCode, 0)
    XCTAssertEqual(draft.directHotkey, hotkey)
    XCTAssertEqual(draft.target.lastKnownURL, replacementURL)

    await module.commitEditing()
    let saved = try XCTUnwrap(module.currentConfiguration.bindings[0])
    XCTAssertEqual(saved.id, item.id)
    XCTAssertEqual(saved.directHotkey, hotkey)
    XCTAssertEqual(saved.target.lastKnownURL, replacementURL)
  }

  func testStaleBookmarkRefreshFailureDoesNotReverseSuccessfulOpen() async throws {
    let originalBookmark = Data("old-bookmark".utf8)
    let target = LaunchTarget(
      kind: .file,
      displayName: "document.txt",
      lastKnownURL: URL(fileURLWithPath: "/tmp/old-document.txt"),
      bookmarkData: originalBookmark
    )
    let item = BindingRecord(
      id: BindingID(rawValue: "stale-document"),
      physicalKeyCode: 0,
      target: target
    )
    let original = LauncherConfiguration(bindings: [0: item])
    let store = MemoryConfigurationStore(configuration: original)
    store.shouldFailSave = true
    let opener = RecordingWorkspaceOpener()
    let resolvedURL = URL(fileURLWithPath: "/tmp/moved-document.txt")
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: StaleBookmarkResolver(resolvedURL: resolvedURL),
      opener: opener,
      ownerLease: HotkeyOwnerLease()
    )
    try await module.start()

    await module.executeBinding(keyCode: 0, source: .directHotkey)

    XCTAssertEqual(opener.openedTargets, [target])
    XCTAssertTrue(module.invalidKeyCodes.isEmpty)
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertNil(module.errorMessage)
    XCTAssertTrue(module.statusText.contains("不影响本次打开"))
  }

  func testDisablingDirectModeImmediatelyUnregistersDirectKeys() async throws {
    let item = record(id: "a", slot: 0, name: "A", hotkeyKey: 3)
    let registrar = ModuleFakeHotkeyRegistrar()
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
    )
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    XCTAssertNotNil(registrar.registrations[.direct(bindingID: item.id)])

    await module.setDirectModeEnabled(false)

    XCTAssertNil(registrar.registrations[.direct(bindingID: item.id)])
    XCTAssertFalse(store.configuration.directModeEnabled)
  }

  func testPanelOnlySingleCommitDoesNotResumePreviouslyPausedShortcuts() async throws {
    let existing = record(id: "existing-paused", slot: 1, name: "Existing", hotkeyKey: 4)
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(
        directModeEnabled: false,
        bindings: [1: existing]
      )
    )
    let module = makeModule(store: store)
    try await module.start()

    module.requestBinding(for: PhysicalKeyCode.q)
    module.bindWebURL("https://panel-only.example", to: PhysicalKeyCode.q)
    module.setDraftDirectHotkey(
      HotkeyDefinition(keyCode: 3, modifiers: [.command, .option]),
      for: PhysicalKeyCode.q
    )
    XCTAssertTrue(module.directModeEnabled)

    module.setDraftDirectHotkey(nil, for: PhysicalKeyCode.q)
    await module.commitEditing()

    XCTAssertFalse(store.configuration.directModeEnabled)
    XCTAssertNil(store.configuration.bindings[PhysicalKeyCode.q]?.directHotkey)
    XCTAssertEqual(store.configuration.bindings[1]?.directHotkey, existing.directHotkey)
  }

  func testRecorderSessionTemporarilyRemovesAndRestoresActualHotkeys() async throws {
    let item = record(id: "recorder-isolation", slot: 0, name: "A", hotkeyKey: 3)
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
      ),
      opener: opener
    )
    try await module.start()
    let sessionID = UUID()

    let recorderReady = await module.beginHotkeyRecorderSession(sessionID)
    XCTAssertTrue(recorderReady)

    XCTAssertTrue(module.isHotkeyRecorderReady)
    XCTAssertTrue(registrar.registrations.isEmpty)
    XCTAssertTrue(module.snapshot.directHotkeysPaused)
    registrar.trigger(.panel)
    registrar.trigger(.direct(bindingID: item.id))
    await Task.yield()
    XCTAssertTrue(opener.openedTargets.isEmpty)

    await module.endHotkeyRecorderSession(sessionID)

    XCTAssertFalse(module.isHotkeyRecorderReady)
    XCTAssertEqual(registrar.registrations[.panel], module.currentConfiguration.panelHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], item.directHotkey)
  }

  func testCommitIsRejectedWhileRecorderIsolationIsActiveAndOldGraphRestores() async throws {
    let item = record(id: "recorder-commit-guard", slot: 0, name: "Old", hotkeyKey: 3)
    let original = LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
    let registrar = ModuleFakeHotkeyRegistrar()
    let store = MemoryConfigurationStore(configuration: original)
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    module.beginEditing()
    module.bindWebURL("https://candidate.example", to: 0)
    let sessionID = UUID()
    let recorderReady = await module.beginHotkeyRecorderSession(sessionID)
    XCTAssertTrue(recorderReady)

    let result = await module.commitEditingWithResult()

    XCTAssertEqual(result, .rejected(reason: .transactionInProgress))
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(store.saveCount, 0)
    XCTAssertTrue(registrar.registrations.isEmpty)

    await module.endHotkeyRecorderSession(sessionID)
    XCTAssertEqual(registrar.registrations[.panel], original.panelHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], item.directHotkey)
  }

  func testRecorderCloseDuringSuspendedIsolationStillRestoresRegistrationGraph() async throws {
    let item = record(id: "recorder-race", slot: 0, name: "A", hotkeyKey: 3)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
      )
    )
    try await module.start()
    registrar.shouldSuspendUnregisterAllOnce = true
    let sessionID = UUID()

    let beginTask = Task { await module.beginHotkeyRecorderSession(sessionID) }
    while !registrar.isUnregisterAllSuspended { await Task.yield() }
    let endTask = Task { await module.endHotkeyRecorderSession(sessionID) }
    await Task.yield()
    registrar.resumeSuspendedUnregisterAll()
    _ = await beginTask.value
    await endTask.value

    XCTAssertEqual(registrar.registrations[.panel], module.currentConfiguration.panelHotkey)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: item.id)], item.directHotkey)
    XCTAssertFalse(module.isHotkeyRecorderReady)
  }

  func testStopWaitsForSuspendedRecorderRestoreAndLeavesNoRegistrations() async throws {
    let item = record(id: "recorder-stop-race", slot: 0, name: "A", hotkeyKey: 3)
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(
      registrar: registrar,
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
      )
    )
    try await module.start()
    let sessionID = UUID()
    await module.beginHotkeyRecorderSession(sessionID)
    registrar.shouldSuspendUnregisterAllOnce = true

    let restoreTask = Task { await module.endHotkeyRecorderSession(sessionID) }
    while !registrar.isUnregisterAllSuspended { await Task.yield() }
    let stopProbe = AsyncCompletionProbe()
    let stopTask = Task {
      await module.stop()
      stopProbe.didFinish = true
    }
    await Task.yield()

    XCTAssertFalse(stopProbe.didFinish)
    registrar.resumeSuspendedUnregisterAll()
    await restoreTask.value
    await stopTask.value

    XCTAssertEqual(module.snapshot.lifecycleState, .stopped)
    XCTAssertTrue(registrar.registrations.isEmpty)
    XCTAssertTrue(module.registrationLedgerSnapshot.registeredBindingIDs.isEmpty)
  }

  func testResumeAllIsolatesOnePersistedConflictAndCommitsOtherBindings() async throws {
    let first = record(id: "resume-a", slot: 0, name: "A", hotkeyKey: 3)
    let second = record(id: "resume-s", slot: 1, name: "S", hotkeyKey: 4)
    let registrar = ModuleFakeHotkeyRegistrar()
    registrar.failureBudgetByHotkey[second.directHotkey!] = 1
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(
        directModeEnabled: false,
        bindings: [0: first, 1: second]
      )
    )
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    await module.setDirectModeEnabled(true)

    XCTAssertTrue(store.configuration.directModeEnabled)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: first.id)], first.directHotkey)
    XCTAssertNil(registrar.registrations[.direct(bindingID: second.id)])
    XCTAssertEqual(module.directConflictKeyCodes, [1])
  }

  func testCompatibilityPauseRejectsOpenDraftWithoutCommittingIt() async throws {
    let item = record(id: "guard-draft", slot: 0, name: "A", hotkeyKey: 3)
    let store = MemoryConfigurationStore(
      configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
    )
    let module = makeModule(store: store)
    try await module.start()
    module.beginEditing()
    module.bindWebURL("https://unsaved.example", to: 0)

    await module.setDirectModeEnabled(false)

    XCTAssertTrue(module.isEditing)
    XCTAssertEqual(store.saveCount, 0)
    XCTAssertTrue(store.configuration.directModeEnabled)
    XCTAssertEqual(store.configuration.bindings[0]?.target.displayName, "A")
    XCTAssertTrue(module.statusText.contains("保存或取消"))
  }

  func testStoppedPublicExecutionIsRejectedWithoutOpeningTarget() async throws {
    let item = record(id: "stopped-execution", slot: 0, name: "A", hotkeyKey: 3)
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(directModeEnabled: true, bindings: [0: item])
      ),
      opener: opener
    )
    try await module.start()
    await module.stop()

    let result = await module.executeWithResult(bindingID: item.id, source: .panelClick)

    XCTAssertEqual(result, .failed(item.id, code: .moduleUnavailable))
    XCTAssertTrue(opener.openedTargets.isEmpty)
    XCTAssertEqual(module.snapshot.lifecycleState, .stopped)
    if case .paused(let hotkey) = module.bindingPresentation(for: 0).runtimeState {
      XCTAssertEqual(hotkey, item.directHotkey)
    } else {
      XCTFail("A persisted shortcut must be paused, not conflicted, after stop")
    }

    module.presentPanel()
    XCTAssertTrue(module.statusText.contains("尚未运行"))
  }

  func testDuplicateDraftMessageNamesBothTargetsAndCombination() async throws {
    let module = makeModule()
    try await module.start()
    let duplicate = HotkeyDefinition(keyCode: 3, modifiers: [.command, .option])
    module.beginEditing()
    module.bindWebURL("https://alpha.example", to: 0)
    module.bindWebURL("https://beta.example", to: 1)
    module.setDraftDirectHotkey(duplicate, for: 0)
    module.setDraftDirectHotkey(duplicate, for: 1)

    let message = try XCTUnwrap(module.draftValidationMessage)
    XCTAssertTrue(message.contains("alpha.example"))
    XCTAssertTrue(message.contains("beta.example"))
    XCTAssertTrue(message.contains(module.hotkeyDisplayName(duplicate)))
  }

  func testUnavailableTargetRepairRejectsChangingTargetKind() async throws {
    let originalTarget = LaunchTarget(
      kind: .file,
      displayName: "missing.txt",
      lastKnownURL: URL(fileURLWithPath: "/tmp/private/missing.txt"),
      bookmarkData: Data("missing".utf8)
    )
    let item = BindingRecord(
      id: BindingID(rawValue: "repair-kind"),
      physicalKeyCode: 0,
      target: originalTarget
    )
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(bindings: [0: item])
      ),
      bookmarkResolver: FailingBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      targetPicker: StubTargetPicker(url: URL(fileURLWithPath: "/tmp/replacement.app"))
    )
    try await module.start()
    _ = await module.executeWithResult(bindingID: item.id, source: .directHotkey)
    module.requestBinding(for: 0)

    module.chooseTarget(kind: .application, for: 0)

    XCTAssertEqual(module.bindingRecord(for: 0)?.target, originalTarget)
    XCTAssertTrue(module.statusText.contains("同类型"))
  }

  func testQuickWebBindingCreatesAndEnablesControlSlotShortcutWithoutRecorderIsolation() async throws {
    let registrar = ModuleFakeHotkeyRegistrar()
    let store = MemoryConfigurationStore()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))
    let chooserSnapshot = QuickBindingChooserSnapshot(
      rawInput: "example.com/path?q=1",
      selectedCandidateID: "web:https://example.com/path?q=1",
      focusIntent: .candidateList,
      showsShortcutOptions: true,
      selectedModifiers: .control,
      usesPanelOnly: false,
      shortcutWasCustomized: false
    )
    module.updateQuickBindingChooserSnapshot(chooserSnapshot, sessionID: session.id)
    XCTAssertEqual(module.quickBindingRequestKeyCode, 0)
    XCTAssertFalse(module.isEditing)

    let result = try await module.quickBindWebURL(
      "example.com/path?q=1",
      to: 0,
      shortcutChoice: .defaultForNew,
      sessionID: session.id
    )

    guard case .committed = result else {
      return XCTFail("Expected quick binding to commit, got \(result)")
    }
    let saved = try XCTUnwrap(store.configuration.bindings[0])
    let expectedHotkey = HotkeyDefinition(keyCode: 0, modifiers: .control)
    XCTAssertEqual(saved.target.lastKnownURL.absoluteString, "https://example.com/path?q=1")
    XCTAssertEqual(saved.directHotkey, expectedHotkey)
    XCTAssertTrue(store.configuration.directModeEnabled)
    XCTAssertEqual(registrar.registrations[.direct(bindingID: saved.id)], expectedHotkey)
    XCTAssertEqual(registrar.unregisterAllCount, 0)
    XCTAssertNil(module.quickBindingRequestKeyCode)
    XCTAssertNil(module.quickBindingSession)
    XCTAssertFalse(module.isEditing)
    XCTAssertEqual(module.feedbackEvent?.slotKeyCode, 0)
    XCTAssertNotNil(module.feedbackEvent?.undoToken)
  }

  func testSuccessfulQuickWebsiteBindingRequestsNewBindingIconAfterCommit() async throws {
    let provider = RecordingWebsiteIconProvider()
    let store = MemoryConfigurationStore()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      uiPreferencesStore: MemoryLauncherUIPreferencesStore(),
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: provider
    )
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

    let result = try await module.quickBindWebURL(
      "example.com/private/path?token=fixture",
      to: 0,
      shortcutChoice: .defaultForNew,
      sessionID: session.id
    )
    guard case .committed = result else {
      return XCTFail("Expected website binding to commit, got \(result)")
    }
    await provider.waitForIconRequestCount(1)

    let savedRecord = try XCTUnwrap(store.configuration.bindings[0])
    let requests = await provider.recordedIconRequests()
    let refreshRequests = await provider.recordedRefreshRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.bindingID, savedRecord.id)
    XCTAssertEqual(requests.first?.websiteURL, savedRecord.target.lastKnownURL)
    XCTAssertEqual(requests.first?.reason, .newBinding)
    XCTAssertEqual(refreshRequests.count, 0)
    XCTAssertEqual(store.saveCount, 1)
  }

  func testModuleSynchronizesWebsiteIconPreferenceAtStartAndAfterPersistedToggle() async throws {
    var initialPreferences = LauncherUIPreferences.defaults
    initialPreferences.onlineWebsiteIconsEnabled = false
    let preferencesStore = MemoryLauncherUIPreferencesStore(preferences: initialPreferences)
    let provider = RecordingWebsiteIconProvider()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: MemoryConfigurationStore(),
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      uiPreferencesStore: preferencesStore,
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: provider
    )

    try await module.start()
    let startupOnlineChanges = await provider.recordedOnlineChanges()
    XCTAssertEqual(startupOnlineChanges, [false])
    XCTAssertFalse(module.uiPreferences.onlineWebsiteIconsEnabled)

    let didSave = await module.setOnlineWebsiteIconsEnabled(true)

    XCTAssertTrue(didSave)
    let storedPreferences = await preferencesStore.storedPreferences()
    let saveCount = await preferencesStore.numberOfSaves()
    let onlineChanges = await provider.recordedOnlineChanges()
    XCTAssertTrue(storedPreferences.onlineWebsiteIconsEnabled)
    XCTAssertEqual(saveCount, 1)
    XCTAssertEqual(onlineChanges, [false, true])
  }

  func testBackfillRequestsOnlyExistingWebsitesWithExplicitReason() async throws {
    let firstWebsite = record(id: "backfill-first", slot: 0, name: "First", hotkeyKey: 3)
    let secondWebsite = record(id: "backfill-second", slot: 2, name: "Second", hotkeyKey: 5)
    let application = BindingRecord(
      id: BindingID(rawValue: "backfill-application"),
      physicalKeyCode: 1,
      target: LaunchTarget(
        kind: .application,
        displayName: "Application",
        lastKnownURL: URL(fileURLWithPath: "/Applications/Fixture.app")
      )
    )
    let provider = RecordingWebsiteIconProvider()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: MemoryConfigurationStore(configuration: LauncherConfiguration(bindings: [
        0: firstWebsite,
        1: application,
        2: secondWebsite,
      ])),
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      uiPreferencesStore: MemoryLauncherUIPreferencesStore(),
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: provider
    )
    try await module.start()

    await module.backfillWebsiteIcons()

    let requests = await provider.recordedIconRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(Set(requests.map(\.bindingID)), Set([firstWebsite.id, secondWebsite.id]))
    XCTAssertTrue(requests.allSatisfy { $0.reason == .explicitBackfill })
    XCTAssertFalse(requests.contains { $0.bindingID == application.id })
  }

  func testStopCancelsInFlightWebsiteIconBackfillWithoutLateFeedback() async throws {
    let website = record(id: "backfill-cancel", slot: 0, name: "Cancel", hotkeyKey: 3)
    let provider = RecordingWebsiteIconProvider(suspendsIconRequests: true)
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: MemoryConfigurationStore(
        configuration: LauncherConfiguration(bindings: [0: website])
      ),
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      uiPreferencesStore: MemoryLauncherUIPreferencesStore(),
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: provider
    )
    try await module.start()

    let backfillTask = Task { @MainActor in
      await module.backfillWebsiteIcons()
    }
    await provider.waitForIconRequestCount(1)

    await module.stop()
    await backfillTask.value

    let cancelCount = await provider.numberOfCancellations()
    XCTAssertEqual(cancelCount, 1)
    XCTAssertNil(module.feedbackEvent)
    XCTAssertEqual(module.snapshot.lifecycleState, .stopped)
  }

  func testIndependentLauncherSettingsCommitDoesNotCreateBatchDraft() async throws {
    let existing = record(id: "settings-existing", slot: 0, name: "Existing", hotkeyKey: 3)
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: existing]
    ))
    let module = makeModule(store: store)
    try await module.start()
    let replacementPanelHotkey = HotkeyDefinition(
      keyCode: 14,
      modifiers: [.command, .option]
    )

    XCTAssertFalse(module.isEditing)
    XCTAssertNil(module.editingSession)
    XCTAssertNil(module.singleBindingTransaction)

    let result = await module.applyLauncherSettings(
      panelHotkey: replacementPanelHotkey,
      directModeEnabled: false
    )

    guard case .committed = result else {
      return XCTFail("Expected independent settings commit, got \(result)")
    }
    XCTAssertFalse(module.isEditing)
    XCTAssertNil(module.editingSession)
    XCTAssertNil(module.singleBindingTransaction)
    XCTAssertEqual(store.saveCount, 1)
    XCTAssertEqual(store.configuration.panelHotkey, replacementPanelHotkey)
    XCTAssertFalse(store.configuration.directModeEnabled)
    XCTAssertEqual(store.configuration.bindings[0], existing)
  }

  func testIndependentPanelHotkeyCommitPublishesSpecificFeedback() async throws {
    let store = MemoryConfigurationStore()
    let module = makeModule(store: store)
    try await module.start()
    let replacement = HotkeyDefinition(
      keyCode: 13,
      modifiers: [.command, .option]
    )

    let result = await module.applyLauncherSettings(
      panelHotkey: replacement,
      directModeEnabled: module.currentConfiguration.directModeEnabled
    )

    guard case .committed = result else {
      return XCTFail("Expected independent panel-hotkey commit, got \(result)")
    }
    let expectedMessage = "打开面板快捷键已修改为 \(module.hotkeyDisplayName(replacement))。"
    XCTAssertEqual(module.statusText, expectedMessage)
    XCTAssertEqual(module.feedbackEvent?.message, expectedMessage)
    XCTAssertEqual(store.configuration.panelHotkey, replacement)
    XCTAssertEqual(store.saveCount, 1)
  }

  func testIndependentPanelHotkeyCommitRejectsStaleRevisionWithoutOverwritingLatestValue()
    async throws
  {
    let store = MemoryConfigurationStore()
    let module = makeModule(store: store)
    try await module.start()
    let staleRevision = module.configurationRevision
    let latest = HotkeyDefinition(
      keyCode: 13,
      modifiers: [.command, .option]
    )
    let staleCandidate = HotkeyDefinition(
      keyCode: 14,
      modifiers: [.command, .option]
    )

    let latestResult = await module.applyLauncherSettings(
      panelHotkey: latest,
      directModeEnabled: module.currentConfiguration.directModeEnabled
    )
    guard case .committed = latestResult else {
      return XCTFail("Expected latest settings commit, got \(latestResult)")
    }
    let latestRevision = module.configurationRevision

    let staleResult = await module.applyLauncherSettings(
      panelHotkey: staleCandidate,
      directModeEnabled: module.currentConfiguration.directModeEnabled,
      expectedConfigurationRevision: staleRevision
    )

    XCTAssertEqual(staleResult, .rejected(reason: .staleRevision))
    XCTAssertEqual(module.configurationRevision, latestRevision)
    XCTAssertEqual(module.currentConfiguration.panelHotkey, latest)
    XCTAssertEqual(store.configuration.panelHotkey, latest)
    XCTAssertEqual(store.saveCount, 1)
  }

  func testSuccessfulPanelHotkeyRetryClearsThePreviousRegistrationError() async throws {
    let registrar = ModuleFakeHotkeyRegistrar()
    let store = MemoryConfigurationStore()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    let unavailable = HotkeyDefinition(
      keyCode: 13,
      modifiers: [.command, .option]
    )
    let available = HotkeyDefinition(
      keyCode: 14,
      modifiers: [.command, .option]
    )
    registrar.failureBudgetByHotkey[unavailable] = 1

    let failedResult = await module.applyLauncherSettings(
      panelHotkey: unavailable,
      directModeEnabled: module.currentConfiguration.directModeEnabled
    )
    guard case .registrationFailed = failedResult else {
      return XCTFail("Expected registration failure, got \(failedResult)")
    }
    XCTAssertNotNil(module.errorMessage)

    let successfulResult = await module.applyLauncherSettings(
      panelHotkey: available,
      directModeEnabled: module.currentConfiguration.directModeEnabled
    )

    guard case .committed = successfulResult else {
      return XCTFail("Expected successful retry, got \(successfulResult)")
    }
    XCTAssertNil(module.errorMessage)
    XCTAssertEqual(module.currentConfiguration.panelHotkey, available)
    XCTAssertEqual(store.configuration.panelHotkey, available)
  }

  func testQuickReplacementPreservesBindingIdentityAndExistingCustomShortcut() async throws {
    let existing = BindingRecord(
      id: BindingID(rawValue: "quick-existing"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .web,
        displayName: "Old",
        lastKnownURL: try XCTUnwrap(URL(string: "https://old.example"))
      ),
      directHotkey: HotkeyDefinition(keyCode: 3, modifiers: [.command, .shift])
    )
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: existing]
    ))
    let module = makeModule(store: store)
    try await module.start()
    module.requestQuickBinding(for: 0)

    let result = try await module.quickBindWebURL(
      "new.example",
      to: 0,
      shortcutChoice: .preserveExisting
    )

    guard case .committed = result else {
      return XCTFail("Expected replacement to commit, got \(result)")
    }
    let saved = try XCTUnwrap(store.configuration.bindings[0])
    XCTAssertEqual(saved.id, existing.id)
    XCTAssertEqual(saved.directHotkey, existing.directHotkey)
    XCTAssertEqual(saved.target.lastKnownURL.absoluteString, "https://new.example")
  }

  func testQuickBindingHonorsPersistedPauseWhenOtherDirectShortcutsExist() async throws {
    let paused = record(id: "paused-existing", slot: 1, name: "Paused", hotkeyKey: 4)
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(
      directModeEnabled: false,
      bindings: [1: paused]
    ))
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    module.requestQuickBinding(for: 0)

    let result = try await module.quickBindWebURL(
      "paused-new.example",
      to: 0,
      shortcutChoice: .defaultForNew
    )

    guard case .committed = result else {
      return XCTFail("Expected paused quick binding to save, got \(result)")
    }
    XCTAssertFalse(store.configuration.directModeEnabled)
    XCTAssertEqual(
      store.configuration.bindings[0]?.directHotkey,
      HotkeyDefinition(keyCode: 0, modifiers: .control)
    )
    XCTAssertEqual(registrar.registrations, [.panel: .defaultPanel])
    XCTAssertTrue(module.statusText.contains("暂停"))
    XCTAssertNil(module.quickBindingSession)
  }

  func testQuickBindingRejectsAStaleSessionBeforeExplicitRetry() async throws {
    let store = MemoryConfigurationStore()
    let module = makeModule(store: store)
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

    var hostConfiguration = module.currentConfiguration
    hostConfiguration.bindings[1] = BindingRecord(
      id: BindingID(rawValue: "host-published-during-quick-session"),
      physicalKeyCode: 1,
      target: LaunchTarget(
        kind: .web,
        displayName: "Host",
        lastKnownURL: try XCTUnwrap(URL(string: "https://host-change.example"))
      )
    )
    let hostResult = await module.commit(LauncherCommitRequest(
      expectedConfigurationRevision: session.expectedConfigurationRevision,
      candidateConfiguration: hostConfiguration
    ))
    guard case .committed = hostResult else {
      return XCTFail("Expected host configuration to commit, got \(hostResult)")
    }

    let staleResult = try await module.quickBindWebURL(
      "user-choice.example",
      to: 0,
      shortcutChoice: .defaultForNew,
      sessionID: session.id
    )
    XCTAssertEqual(staleResult, .rejected(reason: .staleRevision))
    XCTAssertNil(store.configuration.bindings[0])
    XCTAssertEqual(
      store.configuration.bindings[1]?.target.lastKnownURL.absoluteString,
      "https://host-change.example"
    )
    XCTAssertEqual(module.quickBindingSession?.id, session.id)
    XCTAssertEqual(
      module.quickBindingSession?.expectedConfigurationRevision,
      module.configurationRevision
    )

    let confirmedResult = try await module.quickBindWebURL(
      "user-choice.example",
      to: 0,
      shortcutChoice: .defaultForNew,
      sessionID: session.id
    )
    guard case .committed = confirmedResult else {
      return XCTFail("Expected explicit retry to commit, got \(confirmedResult)")
    }
    XCTAssertEqual(
      store.configuration.bindings[0]?.target.lastKnownURL.absoluteString,
      "https://user-choice.example"
    )
  }

  func testSelectedLocalTargetCanRetryAConflictWithoutOpeningPickerAgain() async throws {
    let selectedURL = URL(fileURLWithPath: "/tmp/quick-target.txt")
    let picker = StubTargetPicker(url: selectedURL)
    let registrar = ModuleFakeHotkeyRegistrar()
    let firstChoice = HotkeyDefinition(keyCode: 0, modifiers: .control)
    registrar.failureBudgetByHotkey[firstChoice] = 1
    let store = MemoryConfigurationStore()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      targetPicker: picker
    )
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

    let selected = try await module.selectQuickTarget(
      kind: .file,
      for: 0,
      sessionID: session.id
    )
    let url = try XCTUnwrap(selected)
    let conflicted = try await module.quickBindTarget(
      url: url,
      kind: .file,
      to: 0,
      shortcutChoice: .defaultForNew,
      sessionID: session.id
    )
    guard case .registrationFailed = conflicted else {
      return XCTFail("Expected the first modifier to conflict, got \(conflicted)")
    }
    let recoveredPresentation = try XCTUnwrap(module.quickBindingSession)
    XCTAssertNotEqual(recoveredPresentation.presentationID, session.presentationID)
    module.quickBindingPresentationDidDismiss(
      for: 0,
      sessionID: session.id,
      presentationID: session.presentationID
    )
    XCTAssertEqual(module.quickBindingSession?.presentationID, recoveredPresentation.presentationID)

    let retried = try await module.quickBindTarget(
      url: url,
      kind: .file,
      to: 0,
      shortcutChoice: .customModifiers(.option),
      sessionID: session.id
    )
    guard case .committed = retried else {
      return XCTFail("Expected the in-memory target retry to commit, got \(retried)")
    }
    XCTAssertEqual(picker.chooseCount, 1)
    XCTAssertEqual(store.configuration.bindings[0]?.target.lastKnownURL, selectedURL)
    XCTAssertEqual(
      store.configuration.bindings[0]?.directHotkey,
      HotkeyDefinition(keyCode: 0, modifiers: .option)
    )
  }

  func testAutomaticPopoverDismissDuringLocalPickersKeepsSessionUntilCommit() async throws {
    let scenarios: [(kind: LaunchTargetKind, url: URL)] = [
      (.file, URL(fileURLWithPath: "/tmp/quick-picker-file.txt")),
      (.folder, URL(fileURLWithPath: "/tmp/quick-picker-folder", isDirectory: true)),
    ]

    for scenario in scenarios {
      let picker = SuspendingTargetPicker()
      let store = MemoryConfigurationStore()
      let module = ShortcutLauncherModule(
        registrar: ModuleFakeHotkeyRegistrar(),
        store: store,
        bookmarkResolver: PassthroughBookmarkResolver(),
        opener: RecordingWorkspaceOpener(),
        ownerLease: HotkeyOwnerLease(),
        targetPicker: picker
      )
      try await module.start()
      let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

      let bindingTask = Task { @MainActor in
        try await module.quickChooseTarget(
          kind: scenario.kind,
          for: 0,
          shortcutChoice: .defaultForNew,
          sessionID: session.id
        )
      }
      await picker.waitUntilPresented()

      XCTAssertEqual(module.quickBindingSession?.phase, .systemPicker)
      XCTAssertFalse(module.isQuickBindingPopoverPresented(for: 0))
      module.quickBindingPresentationDidDismiss(
        for: 0,
        sessionID: session.id,
        presentationID: session.presentationID
      )
      XCTAssertEqual(module.quickBindingSession?.id, session.id)
      XCTAssertEqual(store.saveCount, 0)

      picker.finish(with: scenario.url)
      let optionalResult = try await bindingTask.value
      let result = try XCTUnwrap(optionalResult)
      guard case .committed = result else {
        return XCTFail("Expected \(scenario.kind) binding to commit, got \(result)")
      }
      XCTAssertEqual(store.configuration.bindings[0]?.target.kind, scenario.kind)
      XCTAssertEqual(store.configuration.bindings[0]?.target.lastKnownURL, scenario.url)
      XCTAssertEqual(store.saveCount, 1)
      XCTAssertNil(module.quickBindingSession)
      await module.stop()
    }
  }

  func testQuickBindingPresentationDismissOutsideSystemPickerClosesSession() async throws {
    let module = makeModule()
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

    module.quickBindingPresentationDidDismiss(
      for: 0,
      sessionID: session.id,
      presentationID: session.presentationID
    )

    XCTAssertNil(module.quickBindingSession)
  }

  func testExplicitCloseWhileSystemPickerIsPendingRejectsLateSelection() async throws {
    let picker = SuspendingTargetPicker()
    let store = MemoryConfigurationStore()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      targetPicker: picker
    )
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))
    let bindingTask = Task { @MainActor in
      try await module.quickChooseTarget(
        kind: .file,
        for: 0,
        shortcutChoice: .defaultForNew,
        sessionID: session.id
      )
    }
    await picker.waitUntilPresented()

    module.closeQuickBinding(sessionID: session.id)
    picker.finish(with: URL(fileURLWithPath: "/tmp/ignored-late-selection.txt"))

    do {
      _ = try await bindingTask.value
      XCTFail("A selection returned after explicit close must be rejected")
    } catch {
      XCTAssertNil(module.quickBindingSession)
      XCTAssertEqual(store.saveCount, 0)
      XCTAssertNil(store.configuration.bindings[0])
    }
  }

  func testReplacingTargetWithAStillConflictedShortcutKeepsQuickRecoveryOpen() async throws {
    let hotkey = HotkeyDefinition(keyCode: 0, modifiers: .control)
    let existing = BindingRecord(
      id: BindingID(rawValue: "quick-preserved-runtime-conflict"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .web,
        displayName: "Old",
        lastKnownURL: try XCTUnwrap(URL(string: "https://old-conflict.example"))
      ),
      directHotkey: hotkey
    )
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: existing]
    ))
    let registrar = ModuleFakeHotkeyRegistrar()
    registrar.failureBudgetByHotkey[hotkey] = 1
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    XCTAssertTrue(module.directConflictKeyCodes.contains(0))
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

    let replacement = try await module.quickBindWebURL(
      "new-conflict.example",
      to: 0,
      shortcutChoice: .preserveExisting,
      sessionID: session.id
    )
    guard case .committed(_, let enabled) = replacement else {
      return XCTFail("Expected target replacement to save, got \(replacement)")
    }
    XCTAssertTrue(enabled.isEmpty)
    XCTAssertEqual(module.quickBindingSession?.id, session.id)
    XCTAssertTrue(module.statusText.contains("仍被占用"))

    let recovered = try await module.quickBindWebURL(
      "new-conflict.example",
      to: 0,
      shortcutChoice: .customModifiers(.option),
      sessionID: session.id
    )
    guard case .committed = recovered else {
      return XCTFail("Expected modifier recovery to commit, got \(recovered)")
    }
    XCTAssertNil(module.quickBindingSession)
    XCTAssertEqual(
      store.configuration.bindings[0]?.directHotkey,
      HotkeyDefinition(keyCode: 0, modifiers: .option)
    )
  }

  func testQuickApplicationBindingKeepsCatalogDisplayName() async throws {
    let module = makeModule()
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

    let result = try await module.quickBindTarget(
      url: URL(fileURLWithPath: "/Applications/WeChat.app"),
      kind: .application,
      to: 0,
      shortcutChoice: .defaultForNew,
      preferredDisplayName: "微信",
      sessionID: session.id
    )

    guard case .committed = result else {
      return XCTFail("Expected application binding to commit, got \(result)")
    }
    XCTAssertEqual(module.bindingRecord(for: 0)?.target.displayName, "微信")
  }

  func testQuickRepairCanReplaceAnUnavailableFileWithAnySupportedTargetKind() async throws {
    let original = BindingRecord(
      id: BindingID(rawValue: "quick-cross-kind-repair"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .file,
        displayName: "Missing",
        lastKnownURL: URL(fileURLWithPath: "/tmp/missing-quick-repair.txt"),
        bookmarkData: Data("missing".utf8)
      )
    )
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(bindings: [0: original]))
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: FailingBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease()
    )
    try await module.start()
    _ = await module.executeWithResult(bindingID: original.id, source: .panelClick)
    XCTAssertTrue(module.invalidKeyCodes.contains(0))
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))

    let result = try await module.quickBindWebURL(
      "replacement.example",
      to: 0,
      shortcutChoice: .preserveExisting,
      sessionID: session.id
    )
    guard case .committed = result else {
      return XCTFail("Expected cross-kind repair to commit, got \(result)")
    }
    XCTAssertEqual(store.configuration.bindings[0]?.target.kind, .web)
    XCTAssertFalse(module.invalidKeyCodes.contains(0))
  }

  func testQuickBindingConflictKeepsPopoverRequestAndOldConfigurationUntouched() async throws {
    let registrar = ModuleFakeHotkeyRegistrar()
    let conflicted = HotkeyDefinition(keyCode: 0, modifiers: .control)
    registrar.failureBudgetByHotkey[conflicted] = 1
    let store = MemoryConfigurationStore()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()
    module.requestQuickBinding(for: 0)

    let result = try await module.quickBindWebURL(
      "conflict.example",
      to: 0,
      shortcutChoice: .defaultForNew
    )

    guard case .registrationFailed(_, let combination) = result else {
      return XCTFail("Expected registration failure, got \(result)")
    }
    XCTAssertEqual(combination, conflicted)
    XCTAssertEqual(module.currentConfiguration, LauncherConfiguration())
    XCTAssertEqual(store.configuration, LauncherConfiguration())
    XCTAssertEqual(store.saveCount, 0)
    XCTAssertEqual(module.quickBindingRequestKeyCode, 0)
    XCTAssertFalse(module.isEditing)
    XCTAssertEqual(registrar.registrations, [.panel: .defaultPanel])
  }

  func testQuickBindingFailureRestoresSameSessionSnapshotAndPendingTarget() async throws {
    let store = MemoryConfigurationStore()
    store.shouldFailSave = true
    let module = makeModule(store: store)
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))
    let chooserSnapshot = QuickBindingChooserSnapshot(
      rawInput: "failure.example",
      selectedCandidateID: "web:https://failure.example",
      focusIntent: .shortcutOptions,
      showsShortcutOptions: true,
      selectedModifiers: [.command, .option],
      usesPanelOnly: false,
      shortcutWasCustomized: true
    )
    module.updateQuickBindingChooserSnapshot(chooserSnapshot, sessionID: session.id)

    let result = try await module.quickBindWebURL(
      "failure.example",
      to: 0,
      shortcutChoice: .customModifiers([.command, .option]),
      sessionID: session.id
    )

    XCTAssertEqual(result, .persistenceFailed(code: .writeFailed))
    let recoveredSession = try XCTUnwrap(module.quickBindingSession)
    XCTAssertEqual(recoveredSession.id, session.id)
    XCTAssertNotEqual(recoveredSession.presentationID, session.presentationID)
    XCTAssertEqual(recoveredSession.phase, .choosingTarget)
    XCTAssertEqual(recoveredSession.chooserSnapshot, chooserSnapshot)
    XCTAssertEqual(recoveredSession.pendingTarget?.kind, .web)
    XCTAssertEqual(
      recoveredSession.pendingTarget?.url.absoluteString,
      "https://failure.example"
    )
    XCTAssertTrue(module.isQuickBindingPopoverPresented(for: 0))
    XCTAssertEqual(module.currentConfiguration, LauncherConfiguration())
    XCTAssertEqual(store.configuration, LauncherConfiguration())
    XCTAssertEqual(store.saveCount, 0)
  }

  func testPointerExecutionDoesNotWaitForInvocationReleaseGate() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "pointer-immediate"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .web,
        displayName: "Pointer",
        lastKnownURL: try XCTUnwrap(URL(string: "https://pointer.example"))
      )
    )
    let opener = RecordingWorkspaceOpener()
    let module = makeModule(
      store: MemoryConfigurationStore(configuration: LauncherConfiguration(bindings: [0: item])),
      opener: opener
    )
    try await module.start()

    await module.executeBinding(keyCode: 0, source: .panelClick)

    XCTAssertEqual(opener.openedTargets, [item.target])
  }

  func testQuickRemoveCommitsImmediatelyAndNeverDeletesPhysicalTarget() async throws {
    let item = BindingRecord(
      id: BindingID(rawValue: "quick-remove"),
      physicalKeyCode: 0,
      target: LaunchTarget(
        kind: .file,
        displayName: "keep-me.txt",
        lastKnownURL: URL(fileURLWithPath: "/tmp/keep-me.txt")
      ),
      directHotkey: HotkeyDefinition(keyCode: 0, modifiers: .control)
    )
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: item]
    ))
    let registrar = ModuleFakeHotkeyRegistrar()
    let module = makeModule(registrar: registrar, store: store)
    try await module.start()

    let result = await module.quickRemoveBinding(for: 0)

    guard case .committed = result else {
      return XCTFail("Expected removal to commit, got \(result)")
    }
    XCTAssertNil(store.configuration.bindings[0])
    XCTAssertNil(registrar.registrations[.direct(bindingID: item.id)])
  }

  func testQuickRemoveUsesPerSlotBusyAndUndoRestoresBindingAtomically() async throws {
    let removed = record(id: "quick-remove-busy", slot: 0, name: "Removed", hotkeyKey: 3)
    let executable = record(id: "quick-remove-other", slot: 1, name: "Other", hotkeyKey: 4)
    let original = LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: removed, 1: executable]
    )
    let repository = SuspendedSaveConfigurationRepository(configuration: original)
    let registrar = ModuleFakeHotkeyRegistrar()
    let opener = RecordingWorkspaceOpener()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: opener,
      ownerLease: HotkeyOwnerLease(),
      uiPreferencesStore: MemoryLauncherUIPreferencesStore(),
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: NoopWebsiteIconProvider()
    )
    try await module.start()

    let removalTask = Task { @MainActor in
      await module.quickRemoveBinding(for: 0)
    }
    await repository.waitUntilSaveStarts()

    XCTAssertTrue(module.isBusy(0))
    XCTAssertFalse(module.isBusy(1))
    await module.executeBinding(keyCode: 1, source: .panelClick)
    XCTAssertEqual(opener.openedTargets.map(\.displayName), ["Other"])

    await repository.resumeSave()
    guard case .committed = await removalTask.value else {
      return XCTFail("Expected quick removal to commit")
    }
    XCTAssertFalse(module.isBusy(0))
    XCTAssertNil(module.currentConfiguration.bindings[0])
    XCTAssertNil(registrar.registrations[.direct(bindingID: removed.id)])
    let undoToken = try XCTUnwrap(module.feedbackEvent?.undoToken)

    let undoTask = Task { @MainActor in
      await module.undo(undoToken)
    }
    await repository.waitUntilSaveStarts()

    XCTAssertTrue(module.isBusy(0))
    XCTAssertFalse(module.isBusy(1))
    XCTAssertNil(module.currentConfiguration.bindings[0])

    await repository.resumeSave()
    guard case .committed = await undoTask.value else {
      return XCTFail("Expected quick removal undo to commit")
    }
    XCTAssertFalse(module.isBusy(0))
    XCTAssertEqual(module.currentConfiguration, original)
    XCTAssertEqual(
      registrar.registrations[.direct(bindingID: removed.id)],
      removed.directHotkey
    )
    XCTAssertEqual(module.feedbackEvent?.message, "已撤销上一步操作。")
    XCTAssertNil(module.feedbackEvent?.undoToken)
  }

  func testStaleQuickRemoveUndoCannotOverwriteANewerRevision() async throws {
    let removed = record(id: "quick-remove-stale", slot: 0, name: "Removed", hotkeyKey: 3)
    let store = MemoryConfigurationStore(configuration: LauncherConfiguration(
      directModeEnabled: true,
      bindings: [0: removed]
    ))
    let module = makeModule(store: store)
    try await module.start()

    guard case .committed = await module.quickRemoveBinding(for: 0) else {
      return XCTFail("Expected quick removal to commit")
    }
    let undoToken = try XCTUnwrap(module.feedbackEvent?.undoToken)
    let revisionAfterRemoval = module.configurationRevision

    var newerConfiguration = module.currentConfiguration
    let newerRecord = BindingRecord(
      id: BindingID(rawValue: "newer-host-change"),
      physicalKeyCode: 1,
      target: LaunchTarget(
        kind: .web,
        displayName: "Newer",
        lastKnownURL: try XCTUnwrap(URL(string: "https://newer.example"))
      )
    )
    newerConfiguration.bindings[1] = newerRecord
    let newerResult = await module.commit(LauncherCommitRequest(
      expectedConfigurationRevision: revisionAfterRemoval,
      candidateConfiguration: newerConfiguration
    ))
    guard case .committed = newerResult else {
      return XCTFail("Expected newer host change to commit, got \(newerResult)")
    }
    let newerRevision = module.configurationRevision

    let undoResult = await module.undo(undoToken)

    XCTAssertEqual(undoResult, .rejected(reason: .staleRevision))
    XCTAssertEqual(module.configurationRevision, newerRevision)
    XCTAssertEqual(module.currentConfiguration, newerConfiguration)
    XCTAssertEqual(store.configuration, newerConfiguration)
    XCTAssertNil(module.currentConfiguration.bindings[0])
    XCTAssertEqual(module.currentConfiguration.bindings[1], newerRecord)
    XCTAssertEqual(store.saveCount, 2)
    XCTAssertTrue(module.feedbackEvent?.message.contains("不能覆盖") == true)
    XCTAssertNil(module.feedbackEvent?.undoToken)
  }

  func testCancelledQuickSystemPickerRestoresSameSessionPopoverAndChooserSnapshot() async throws {
    let store = MemoryConfigurationStore()
    let module = ShortcutLauncherModule(
      registrar: ModuleFakeHotkeyRegistrar(),
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: RecordingWorkspaceOpener(),
      ownerLease: HotkeyOwnerLease(),
      targetPicker: StubTargetPicker(url: nil),
      uiPreferencesStore: MemoryLauncherUIPreferencesStore(),
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: NoopWebsiteIconProvider()
    )
    try await module.start()
    let session = try XCTUnwrap(module.requestQuickBinding(for: 0))
    let chooserSnapshot = QuickBindingChooserSnapshot(
      rawInput: "微信",
      selectedCandidateID: "application:wechat",
      focusIntent: .fileAction,
      showsShortcutOptions: true,
      selectedModifiers: [.control, .option],
      usesPanelOnly: false,
      shortcutWasCustomized: true
    )
    module.updateQuickBindingChooserSnapshot(chooserSnapshot, sessionID: session.id)

    let result = try await module.quickChooseTarget(
      kind: .file,
      for: 0,
      shortcutChoice: .defaultForNew,
      sessionID: session.id
    )

    XCTAssertNil(result)
    let recoveredSession = try XCTUnwrap(module.quickBindingSession)
    XCTAssertEqual(recoveredSession.id, session.id)
    XCTAssertNotEqual(recoveredSession.presentationID, session.presentationID)
    XCTAssertEqual(recoveredSession.keyCode, session.keyCode)
    XCTAssertEqual(
      recoveredSession.expectedConfigurationRevision,
      session.expectedConfigurationRevision
    )
    XCTAssertEqual(recoveredSession.phase, .choosingTarget)
    XCTAssertEqual(recoveredSession.chooserSnapshot, chooserSnapshot)
    XCTAssertNil(recoveredSession.pendingTarget)
    XCTAssertTrue(module.isQuickBindingPopoverPresented(for: 0))
    module.quickBindingPresentationDidDismiss(
      for: 0,
      sessionID: session.id,
      presentationID: session.presentationID
    )
    XCTAssertEqual(module.quickBindingSession?.id, session.id)
    XCTAssertEqual(module.currentConfiguration, LauncherConfiguration())
    XCTAssertFalse(module.isEditing)
    XCTAssertEqual(store.saveCount, 0)
    XCTAssertNil(module.errorMessage)
  }

  private func makeModule(
    registrar: ModuleFakeHotkeyRegistrar = ModuleFakeHotkeyRegistrar(),
    store: MemoryConfigurationStore = MemoryConfigurationStore(),
    opener: RecordingWorkspaceOpener = RecordingWorkspaceOpener(),
    ownerLease: HotkeyOwnerLease = HotkeyOwnerLease(),
    keyLabelProvider: (any KeyLabelProviding)? = nil
  ) -> ShortcutLauncherModule {
    ShortcutLauncherModule(
      registrar: registrar,
      store: store,
      bookmarkResolver: PassthroughBookmarkResolver(),
      opener: opener,
      ownerLease: ownerLease,
      keyLabelProvider: keyLabelProvider,
      uiPreferencesStore: MemoryLauncherUIPreferencesStore(),
      applicationCatalog: NoopInstalledApplicationCatalog(),
      websiteIconProvider: NoopWebsiteIconProvider()
    )
  }

  private func record(
    id: String,
    slot: UInt16,
    name: String,
    hotkeyKey: UInt16
  ) -> BindingRecord {
    BindingRecord(
      id: BindingID(rawValue: id),
      physicalKeyCode: slot,
      target: LaunchTarget(kind: .web, displayName: name, lastKnownURL: URL(string: "https://\(name.lowercased()).example")!),
      directHotkey: HotkeyDefinition(keyCode: hotkeyKey, modifiers: [.command, .option])
    )
  }
}

private actor MemoryLauncherUIPreferencesStore: LauncherUIPreferencesStoring {
  nonisolated let preferencesURL = URL(fileURLWithPath: "/tmp/test-launcher-ui-preferences.json")
  nonisolated let backupURL = URL(fileURLWithPath: "/tmp/test-launcher-ui-preferences.backup.json")

  private var preferences: LauncherUIPreferences
  private var saveCount = 0

  init(preferences: LauncherUIPreferences = .defaults) {
    self.preferences = preferences
  }

  func load() async throws -> LauncherUIPreferencesLoadResult {
    LauncherUIPreferencesLoadResult(preferences: preferences)
  }

  func save(_ preferences: LauncherUIPreferences) async throws {
    saveCount += 1
    self.preferences = preferences
  }

  func restore(_ preferences: LauncherUIPreferences) async throws {
    self.preferences = preferences
  }

  func storedPreferences() -> LauncherUIPreferences { preferences }
  func numberOfSaves() -> Int { saveCount }
}

private actor NoopInstalledApplicationCatalog: InstalledApplicationCataloging {
  func applications(forceRefresh: Bool) async -> [ApplicationDescriptor] { [] }
  func search(query: String, limit: Int) async -> [ApplicationDescriptor] { [] }
  func prewarm(forceRefresh: Bool) async -> [ApplicationDescriptor] { [] }
  func invalidate() async {}
}

private actor NoopWebsiteIconProvider: WebsiteIconProviding {
  func icon(for request: WebsiteIconRequest) async -> WebsiteIconResult {
    .fallback(.generic)
  }

  func refresh(_ request: WebsiteIconRequest) async -> WebsiteIconResult {
    .fallback(.generic)
  }

  func cancelAll() async {}
}

private actor RecordingWebsiteIconProvider: WebsiteIconManaging {
  private let suspendsIconRequests: Bool
  private var iconRequests: [WebsiteIconRequest] = []
  private var refreshRequests: [WebsiteIconRequest] = []
  private var onlineChanges: [Bool] = []
  private var cancelCount = 0
  private var suspendedIconContinuations: [CheckedContinuation<WebsiteIconResult, Never>] = []
  private var iconRequestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  init(suspendsIconRequests: Bool = false) {
    self.suspendsIconRequests = suspendsIconRequests
  }

  func icon(for request: WebsiteIconRequest) async -> WebsiteIconResult {
    iconRequests.append(request)
    resumeSatisfiedIconRequestWaiters()
    guard suspendsIconRequests else { return .fallback(.generic) }
    return await withCheckedContinuation { continuation in
      suspendedIconContinuations.append(continuation)
    }
  }

  func refresh(_ request: WebsiteIconRequest) async -> WebsiteIconResult {
    refreshRequests.append(request)
    return .fallback(.generic)
  }

  func cancelAll() async {
    cancelCount += 1
    let continuations = suspendedIconContinuations
    suspendedIconContinuations.removeAll()
    for continuation in continuations {
      continuation.resume(returning: .fallback(.generic))
    }
  }

  func updates() async -> AsyncStream<WebsiteIconUpdate> {
    AsyncStream { continuation in continuation.finish() }
  }

  func setOnlineFetchingEnabled(_ enabled: Bool) async {
    onlineChanges.append(enabled)
  }

  func isOnlineFetchingEnabled() async -> Bool {
    onlineChanges.last ?? true
  }

  func clearAutomaticCache() async {}

  func storeCustomIcon(
    imageData: Data,
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation? {
    nil
  }

  func removeCustomIcon(
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation? {
    nil
  }

  func finalizeCustomIconMutation(_ mutation: CustomWebsiteIconMutation) async {}

  func waitForIconRequestCount(_ count: Int) async {
    guard iconRequests.count < count else { return }
    await withCheckedContinuation { continuation in
      iconRequestWaiters.append((count, continuation))
    }
  }

  func recordedIconRequests() -> [WebsiteIconRequest] { iconRequests }
  func recordedRefreshRequests() -> [WebsiteIconRequest] { refreshRequests }
  func recordedOnlineChanges() -> [Bool] { onlineChanges }
  func numberOfCancellations() -> Int { cancelCount }

  private func resumeSatisfiedIconRequestWaiters() {
    var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    for waiter in iconRequestWaiters {
      if iconRequests.count >= waiter.count {
        waiter.continuation.resume()
      } else {
        pending.append(waiter)
      }
    }
    iconRequestWaiters = pending
  }
}

@MainActor
private final class LifecycleKeyLabelProvider: KeyLabelProviding {
  private(set) var snapshot = KeyLabelSnapshot.fallback()
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var refreshCount = 0
  private var isObserving = false

  func refresh() {
    refreshCount += 1
    snapshot = KeyLabelSnapshot(
      revision: snapshot.revision &+ 1,
      labels: snapshot.labels
    )
  }

  func startObserving() {
    guard !isObserving else { return }
    isObserving = true
    startCount += 1
  }

  func stopObserving() {
    guard isObserving else { return }
    isObserving = false
    stopCount += 1
  }
}

@MainActor
private final class ModuleFakeHotkeyRegistrar: HotkeyRegistering {
  var registerCount = 0
  var unregisterAllCount = 0
  var failingIDs: Set<HotkeyID> = []
  var failureBudgetByHotkey: [HotkeyDefinition: Int] = [:]
  var hotkeyToSuspendOnce: HotkeyDefinition?
  private(set) var isRegistrationSuspended = false
  var shouldSuspendUnregisterAllOnce = false
  var shouldFailPreparedCommitOnce = false
  var shouldSuspendAndFailPreparedCommitOnce = false
  private(set) var isUnregisterAllSuspended = false
  private(set) var isPreparedCommitSuspended = false
  var registrations: [HotkeyID: HotkeyDefinition] = [:]
  private var handler: (@MainActor @Sendable (HotkeyID) -> Void)?
  private var suspensionContinuation: CheckedContinuation<Void, Never>?
  private var unregisterAllSuspensionContinuation: CheckedContinuation<Void, Never>?
  private var preparedCommitSuspensionContinuation: CheckedContinuation<Void, Never>?

  func setHandler(_ handler: @escaping @MainActor @Sendable (HotkeyID) -> Void) { self.handler = handler }
  func register(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    registerCount += 1
    await suspendIfNeeded(hotkey)
    if shouldFail(id: id, hotkey: hotkey) {
      throw LauncherError.hotkeyRegistrationFailed(status: -1)
    }
    if registrations.contains(where: { $0.key != id && $0.value == hotkey }) {
      throw LauncherError.hotkeyRegistrationFailed(status: -2)
    }
    registrations[id] = hotkey
  }
  func replace(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    await suspendIfNeeded(hotkey)
    if shouldFail(id: id, hotkey: hotkey) {
      throw LauncherError.hotkeyRegistrationFailed(status: -1)
    }
    if registrations.contains(where: { $0.key != id && $0.value == hotkey }) {
      throw LauncherError.hotkeyRegistrationFailed(status: -2)
    }
    registrations[id] = hotkey
  }
  func reassign(_ hotkey: HotkeyDefinition, from oldID: HotkeyID, to newID: HotkeyID) async throws {
    await suspendIfNeeded(hotkey)
    if shouldFail(id: newID, hotkey: hotkey) {
      throw LauncherError.hotkeyRegistrationFailed(status: -1)
    }
    registrations.removeValue(forKey: oldID)
    registrations[newID] = hotkey
  }
  func commitPreparedRegistrations(
    assignments: [HotkeyID: HotkeyID],
    desiredHotkeys: [HotkeyID: HotkeyDefinition]
  ) async throws {
    if shouldSuspendAndFailPreparedCommitOnce {
      shouldSuspendAndFailPreparedCommitOnce = false
      isPreparedCommitSuspended = true
      await withCheckedContinuation { continuation in
        preparedCommitSuspensionContinuation = continuation
      }
      isPreparedCommitSuspended = false
      throw LauncherError.hotkeyRegistrationFailed(status: -4)
    }
    if shouldFailPreparedCommitOnce {
      shouldFailPreparedCommitOnce = false
      throw LauncherError.hotkeyRegistrationFailed(status: -3)
    }
    guard Set(assignments.values).count == assignments.count,
      Set(assignments.values) == Set(desiredHotkeys.keys)
    else { throw LauncherError.invalidConfiguration("invalid fake registration plan") }
    var next: [HotkeyID: HotkeyDefinition] = [:]
    for (sourceID, destinationID) in assignments {
      guard registrations[sourceID] == desiredHotkeys[destinationID] else {
        throw LauncherError.invalidConfiguration("stale fake registration plan")
      }
      next[destinationID] = desiredHotkeys[destinationID]
    }
    registrations = next
  }
  func unregister(id: HotkeyID) async { registrations.removeValue(forKey: id) }
  func unregisterAll() async {
    unregisterAllCount += 1
    if shouldSuspendUnregisterAllOnce {
      shouldSuspendUnregisterAllOnce = false
      isUnregisterAllSuspended = true
      await withCheckedContinuation { continuation in
        unregisterAllSuspensionContinuation = continuation
      }
      isUnregisterAllSuspended = false
    }
    registrations.removeAll()
  }
  func trigger(_ id: HotkeyID) { handler?(id) }

  @discardableResult
  func trigger(hotkey: HotkeyDefinition) -> Bool {
    guard let id = registrations.first(where: { $0.value == hotkey })?.key else {
      return false
    }
    handler?(id)
    return true
  }

  func resumeSuspendedRegistration() {
    suspensionContinuation?.resume()
    suspensionContinuation = nil
  }

  func resumeSuspendedUnregisterAll() {
    unregisterAllSuspensionContinuation?.resume()
    unregisterAllSuspensionContinuation = nil
  }

  func resumePreparedCommitWithFailure() {
    preparedCommitSuspensionContinuation?.resume()
    preparedCommitSuspensionContinuation = nil
  }

  private func suspendIfNeeded(_ hotkey: HotkeyDefinition) async {
    guard hotkeyToSuspendOnce == hotkey else { return }
    hotkeyToSuspendOnce = nil
    isRegistrationSuspended = true
    await withCheckedContinuation { continuation in
      suspensionContinuation = continuation
    }
    isRegistrationSuspended = false
  }

  private func shouldFail(id: HotkeyID, hotkey: HotkeyDefinition) -> Bool {
    if failingIDs.contains(id) { return true }
    guard let remaining = failureBudgetByHotkey[hotkey], remaining > 0 else { return false }
    if remaining == 1 {
      failureBudgetByHotkey.removeValue(forKey: hotkey)
    } else {
      failureBudgetByHotkey[hotkey] = remaining - 1
    }
    return true
  }
}

@MainActor
private final class AsyncCompletionProbe {
  var didFinish = false
}

@MainActor
private final class MainActorAsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

@MainActor
private final class LifecycleRequestOrderRecorder {
  var requested: [String] = []
  var completed: [String] = []
}

@MainActor
private final class MemoryConfigurationStore: ConfigurationStoring {
  let configurationURL = URL(fileURLWithPath: "/tmp/stage2-memory-configuration.json")
  var configuration: LauncherConfiguration
  var saveCount = 0
  var shouldFailSave = false

  init(configuration: LauncherConfiguration = LauncherConfiguration()) {
    self.configuration = configuration
  }

  func load() throws -> LauncherConfiguration { configuration }
  func save(_ configuration: LauncherConfiguration) throws {
    if shouldFailSave {
      throw LauncherError.configurationWriteFailed("/private-fixture/config.json")
    }
    saveCount += 1
    self.configuration = configuration
  }

  func restore(_ configuration: LauncherConfiguration) throws {
    self.configuration = configuration
  }
}

private actor SuspendedSaveConfigurationRepository: ConfigurationRepositoryProtocol {
  nonisolated let configurationURL = URL(
    fileURLWithPath: "/tmp/shortcut-launcher-suspended-save.json"
  )
  nonisolated let backupURL = URL(
    fileURLWithPath: "/tmp/shortcut-launcher-suspended-save.backup.json"
  )

  private var configuration: LauncherConfiguration
  private var pendingConfiguration: LauncherConfiguration?
  private var saveContinuation: CheckedContinuation<Void, any Error>?
  private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(configuration: LauncherConfiguration) {
    self.configuration = configuration
  }

  func load() async throws -> ConfigurationLoadResult {
    ConfigurationLoadResult(configuration: configuration)
  }

  func save(_ configuration: LauncherConfiguration) async throws {
    pendingConfiguration = configuration
    let waiters = saveStartWaiters
    saveStartWaiters.removeAll()
    for waiter in waiters { waiter.resume() }

    try await withCheckedThrowingContinuation {
      saveContinuation = $0
    }
    self.configuration = configuration
    pendingConfiguration = nil
  }

  func restore(_ configuration: LauncherConfiguration) async throws {
    pendingConfiguration = nil
    self.configuration = configuration
  }

  func exportData(for configuration: LauncherConfiguration) async throws -> Data {
    try JSONEncoder().encode(configuration)
  }

  func prepareImport(_ data: Data) async throws -> PreparedConfigurationImport {
    PreparedConfigurationImport(
      configuration: try JSONDecoder().decode(LauncherConfiguration.self, from: data)
    )
  }

  func waitUntilSaveStarts() async {
    guard pendingConfiguration == nil else { return }
    await withCheckedContinuation { continuation in
      saveStartWaiters.append(continuation)
    }
  }

  func resumeSave() {
    saveContinuation?.resume()
    saveContinuation = nil
  }

  func failSave() {
    pendingConfiguration = nil
    saveContinuation?.resume(
      throwing: LauncherError.configurationWriteFailed("/tmp/private/configuration.json")
    )
    saveContinuation = nil
  }
}

private actor FailingRestoreConfigurationRepository: ConfigurationRepositoryProtocol {
  nonisolated let configurationURL = URL(
    fileURLWithPath: "/tmp/shortcut-launcher-failing-restore.json"
  )
  nonisolated let backupURL = URL(
    fileURLWithPath: "/tmp/shortcut-launcher-failing-restore.backup.json"
  )

  private var configuration: LauncherConfiguration

  init(configuration: LauncherConfiguration) {
    self.configuration = configuration
  }

  func load() async throws -> ConfigurationLoadResult {
    ConfigurationLoadResult(configuration: configuration)
  }

  func save(_ configuration: LauncherConfiguration) async throws {
    self.configuration = configuration
  }

  func restore(_ configuration: LauncherConfiguration) async throws {
    throw LauncherError.configurationWriteFailed("/private-fixture/rollback.json")
  }

  func exportData(for configuration: LauncherConfiguration) async throws -> Data {
    try JSONEncoder().encode(configuration)
  }

  func prepareImport(_ data: Data) async throws -> PreparedConfigurationImport {
    PreparedConfigurationImport(
      configuration: try JSONDecoder().decode(LauncherConfiguration.self, from: data)
    )
  }

  func persistedConfiguration() -> LauncherConfiguration { configuration }
}

private enum ModuleDurabilityFailure: CustomStringConvertible, Equatable, Sendable {
  case directorySync
  case directoryClose

  var description: String {
    switch self {
    case .directorySync: "directory-sync"
    case .directoryClose: "directory-close"
    }
  }
}

private final class ArmableConfigurationFileOperations: ConfigurationFileOperations,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var armedFailure: ModuleDurabilityFailure?
  private var remainingOccurrences = 0

  func arm(_ failure: ModuleDurabilityFailure, occurrence: Int) {
    lock.withLock {
      armedFailure = failure
      remainingOccurrences = occurrence
    }
  }

  func openForSynchronization(at url: URL, isDirectory: Bool) -> Int32 {
    Darwin.open(url.path, O_RDONLY)
  }

  func synchronize(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32 {
    if isDirectory, consumeFailureIfNeeded(.directorySync) { return -1 }
    return Darwin.fsync(descriptor)
  }

  func close(_ descriptor: Int32, at url: URL, isDirectory: Bool) -> Int32 {
    let result = Darwin.close(descriptor)
    if isDirectory, consumeFailureIfNeeded(.directoryClose) { return -1 }
    return result
  }

  private func consumeFailureIfNeeded(_ operation: ModuleDurabilityFailure) -> Bool {
    lock.withLock {
      guard armedFailure == operation else { return false }
      remainingOccurrences -= 1
      guard remainingOccurrences == 0 else { return false }
      armedFailure = nil
      return true
    }
  }
}

private struct PassthroughBookmarkResolver: BookmarkResolving {
  func makeBookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
  func resolve(_ bookmarkData: Data) throws -> ResolvedBookmark {
    let value = String(decoding: bookmarkData, as: UTF8.self)
    return ResolvedBookmark(url: URL(string: value) ?? URL(fileURLWithPath: "/tmp"), isStale: false)
  }
}

private struct FailingBookmarkResolver: BookmarkResolving {
  func makeBookmark(for url: URL) throws -> Data { Data() }
  func resolve(_ bookmarkData: Data) throws -> ResolvedBookmark {
    throw LauncherError.bookmarkResolveFailed("/tmp/private/missing-target.txt")
  }
}

private struct StaleBookmarkResolver: BookmarkResolving {
  let resolvedURL: URL

  func makeBookmark(for url: URL) throws -> Data { Data("new-bookmark".utf8) }
  func resolve(_ bookmarkData: Data) throws -> ResolvedBookmark {
    ResolvedBookmark(url: resolvedURL, isStale: true)
  }
}

@MainActor
private final class StubTargetPicker: TargetPickerPresenting {
  let url: URL?
  private(set) var chooseCount = 0

  init(url: URL?) {
    self.url = url
  }

  func chooseTarget(kind: LaunchTargetKind, panelKeyLabel: String) -> URL? {
    chooseCount += 1
    return url
  }
}

@MainActor
private final class SuspendingTargetPicker: TargetPickerPresenting {
  private var selectionContinuation: CheckedContinuation<URL?, Never>?
  private var presentationWaiters: [CheckedContinuation<Void, Never>] = []
  private var isPresented = false

  func chooseTarget(kind: LaunchTargetKind, panelKeyLabel: String) -> URL? {
    preconditionFailure("SuspendingTargetPicker must use the async picker boundary")
  }

  func chooseTargetAsync(
    kind: LaunchTargetKind,
    panelKeyLabel: String,
    presentationWindow: NSWindow?
  ) async -> URL? {
    await withCheckedContinuation { continuation in
      selectionContinuation = continuation
      isPresented = true
      let waiters = presentationWaiters
      presentationWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  func waitUntilPresented() async {
    guard !isPresented else { return }
    await withCheckedContinuation { presentationWaiters.append($0) }
  }

  func finish(with url: URL?) {
    isPresented = false
    let continuation = selectionContinuation
    selectionContinuation = nil
    continuation?.resume(returning: url)
  }
}

@MainActor
private final class RecordingWorkspaceOpener: WorkspaceOpening {
  var openedTargets: [LaunchTarget] = []
  func open(target: LaunchTarget, resolvedURL: URL) async throws { openedTargets.append(target) }
}

@MainActor
private final class RecordingPanelPresenter: LauncherPanelPresenting {
  private(set) var isVisible = false
  private(set) var showCount = 0
  private(set) var dismissCount = 0
  private(set) var invalidateCount = 0

  func showOnCurrentScreen() {
    showCount += 1
    isVisible = true
  }

  func dismiss() {
    dismissCount += 1
    isVisible = false
  }

  func invalidate() {
    invalidateCount += 1
    isVisible = false
  }
}

@MainActor
private final class SuspendingWorkspaceOpener: WorkspaceOpening {
  private var continuation: CheckedContinuation<Void, Error>?
  private(set) var isSuspended = false

  func open(target: LaunchTarget, resolvedURL: URL) async throws {
    isSuspended = true
    defer { isSuspended = false }
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func fail(with error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

@MainActor
private final class RecordingFeedbackPresenter: LauncherFeedbackPresenting {
  var presented: [LauncherRepairPrompt] = []
  var dismissedBindingIDs: [BindingID] = []

  func present(_ prompt: LauncherRepairPrompt) {
    presented.append(prompt)
  }

  func dismiss(bindingID: BindingID) {
    dismissedBindingIDs.append(bindingID)
  }
}
