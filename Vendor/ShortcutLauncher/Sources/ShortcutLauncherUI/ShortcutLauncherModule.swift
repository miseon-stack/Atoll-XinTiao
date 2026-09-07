import AppKit
import Combine
import Foundation
import OSLog
import ShortcutLauncherCore
import UniformTypeIdentifiers

/// One visible quick-binding interaction. The revision captured when the
/// popover opens prevents a delayed target choice from silently overwriting a
/// host-side configuration change.
public enum QuickBindingPhase: Equatable, Sendable {
  /// The in-app target chooser is visible and accepts user input.
  case choosingTarget
  /// A system file panel owns the interaction; the transient popover is hidden.
  case systemPicker
  /// A complete target choice is being validated and atomically committed.
  case committing

  public var presentsPopover: Bool { self == .choosingTarget }
}

/// A target kept only for the lifetime of one quick-binding session. Keeping
/// recovery state outside the transient SwiftUI popover lets a failed save or
/// hotkey conflict reopen in place without asking the user to choose the file
/// again.
public struct QuickBindingPendingTarget: Equatable, Sendable {
  public let url: URL
  public let kind: LaunchTargetKind
  public let preferredDisplayName: String?
  public let shortcutChoice: QuickBindingShortcutChoice

  public init(
    url: URL,
    kind: LaunchTargetKind,
    preferredDisplayName: String? = nil,
    shortcutChoice: QuickBindingShortcutChoice
  ) {
    self.url = url
    self.kind = kind
    self.preferredDisplayName = preferredDisplayName
    self.shortcutChoice = shortcutChoice
  }
}

public enum QuickBindingFocusIntent: String, Equatable, Hashable, Sendable {
  case primaryInput
  case candidateList
  case applicationAction
  case fileAction
  case folderAction
  case shortcutOptions
}

/// Transient chooser state that survives an AppKit file panel temporarily
/// dismissing the SwiftUI popover. It is never written to schema v3.
public struct QuickBindingChooserSnapshot: Equatable, Sendable {
  public var rawInput: String
  public var selectedCandidateID: String?
  public var focusIntent: QuickBindingFocusIntent
  public var showsShortcutOptions: Bool
  public var selectedModifiers: ModifierSet
  public var usesPanelOnly: Bool
  public var shortcutWasCustomized: Bool

  public init(
    rawInput: String = "",
    selectedCandidateID: String? = nil,
    focusIntent: QuickBindingFocusIntent = .primaryInput,
    showsShortcutOptions: Bool = false,
    selectedModifiers: ModifierSet = [.control],
    usesPanelOnly: Bool = false,
    shortcutWasCustomized: Bool = false
  ) {
    self.rawInput = rawInput
    self.selectedCandidateID = selectedCandidateID
    self.focusIntent = focusIntent
    self.showsShortcutOptions = showsShortcutOptions
    self.selectedModifiers = selectedModifiers
    self.usesPanelOnly = usesPanelOnly
    self.shortcutWasCustomized = shortcutWasCustomized
  }
}

public struct QuickBindingSession: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// Identity of one concrete popover presentation. It changes whenever a
  /// hidden system/commit phase returns to the chooser, so a delayed dismiss
  /// callback from the old popover cannot close the recovered one.
  public let presentationID: UUID
  public let keyCode: UInt16
  public let expectedConfigurationRevision: UInt64
  public let phase: QuickBindingPhase
  public let pendingTarget: QuickBindingPendingTarget?
  public let chooserSnapshot: QuickBindingChooserSnapshot

  public init(
    id: UUID = UUID(),
    presentationID: UUID = UUID(),
    keyCode: UInt16,
    expectedConfigurationRevision: UInt64,
    phase: QuickBindingPhase = .choosingTarget,
    pendingTarget: QuickBindingPendingTarget? = nil,
    chooserSnapshot: QuickBindingChooserSnapshot = QuickBindingChooserSnapshot()
  ) {
    self.id = id
    self.presentationID = presentationID
    self.keyCode = keyCode
    self.expectedConfigurationRevision = expectedConfigurationRevision
    self.phase = phase
    self.pendingTarget = pendingTarget
    self.chooserSnapshot = chooserSnapshot
  }
}

@MainActor
public final class ShortcutLauncherModule: ObservableObject, ShortcutLauncherModuleProtocol,
  ShortcutLauncherControlling
{
  private let logger = Logger(
    subsystem: "io.github.miseon-stack.shortcutlauncher",
    category: "interaction"
  )

  @Published public private(set) var statusText = "尚未启动"
  @Published public private(set) var isArmed = false
  @Published public private(set) var invalidKeyCodes: Set<UInt16> = []
  @Published public private(set) var directConflictKeyCodes: Set<UInt16> = []
  @Published public private(set) var editingSession: BindingEditSession?
  @Published public private(set) var singleBindingTransaction: SingleBindingEditTransaction?
  @Published public private(set) var isCommitting = false
  @Published public var cancelConfirmationRequested = false
  /// The lightweight binding surface owns an explicit, revision-aware session.
  /// It creates no draft; configuration changes begin only after the user has
  /// selected a target and are still committed through the normal transaction.
  @Published public private(set) var quickBindingSession: QuickBindingSession?
  @Published public private(set) var busyKeyCodes: Set<UInt16> = []
  @Published public private(set) var feedbackEvent: LauncherFeedbackEvent?
  @Published public private(set) var uiPreferences = LauncherUIPreferences.defaults
  @Published public private(set) var isSavingUIPreferences = false
  public var quickBindingRequestKeyCode: UInt16? { quickBindingSession?.keyCode }
  public func isQuickBindingPopoverPresented(for keyCode: UInt16) -> Bool {
    guard let session = quickBindingSession, session.keyCode == keyCode else { return false }
    return session.phase.presentsPopover
  }
  @Published public var bindingRequestKeyCode: UInt16?
  @Published public var errorMessage: String?
  @Published public private(set) var repairPrompt: LauncherRepairPrompt?
  @Published public private(set) var keyLabelSnapshot: KeyLabelSnapshot
  @Published public private(set) var configurationRevision: UInt64 = 0
  @Published public private(set) var isHotkeyRecorderReady = false
  @Published private var runtimeIssueCodes: Set<LauncherRuntimeIssueCode> = []
  @Published private var configuration = LauncherConfiguration()

  public var currentConfiguration: LauncherConfiguration { configuration }
  public var displayedConfiguration: LauncherConfiguration {
    editingSession?.draft ?? configuration
  }
  public var bindings: [UInt16: LaunchTarget] { displayedConfiguration.targetBindings }
  public var panelHotkey: HotkeyDefinition { displayedConfiguration.panelHotkey }
  public var directModeEnabled: Bool { displayedConfiguration.directModeEnabled }
  public var isEditing: Bool { editingSession != nil }
  public var isSingleBindingEditing: Bool { singleBindingTransaction != nil }
  public var hasEditingChanges: Bool { editingSession?.hasChanges == true }
  public var qBinding: LaunchTarget? { binding(for: PhysicalKeyCode.q) }
  public var configurationURL: URL { repository.configurationURL }
  public var panelHotkeyDisplayName: String { keyLabelSnapshot.displayName(for: panelHotkey) }
  public var activePanelHotkeyDisplayName: String {
    keyLabelSnapshot.displayName(for: configuration.panelHotkey)
  }
  public var bindingPresentations: [BindingPresentation] {
    BindingStateResolver.resolveAll(from: bindingStateInputSnapshot)
  }
  public var snapshot: LauncherRuntimeSnapshot {
    var issues = Array(runtimeIssueCodes)
    if !directConflictKeyCodes.isEmpty { issues.append(.directHotkeyConflict) }
    if !invalidKeyCodes.isEmpty { issues.append(.targetUnavailable) }
    if lastLoadResult?.recoveredFromBackup == true { issues.append(.configurationRecovered) }
    if !ownsHotkeyLease, lifecycleOperation == .starting { issues.append(.moduleUnavailable) }
    return LauncherRuntimeSnapshot(
      lifecycleState: publicLifecycleState,
      configurationRevision: configurationRevision,
      panelHotkey: configuration.panelHotkey,
      directHotkeysPaused: rawRegistrationLedgerSnapshot.directHotkeysPaused,
      bindings: bindingPresentations.map(BindingRuntimeSummary.init),
      issueCodes: issues
    )
  }
  public var directShortcutSummary: String {
    let count = displayedConfiguration.bindings.values.filter { $0.directHotkey != nil }.count
    return count == 0 ? "尚未设置全局快捷键" : "已设置 \(count) 个全局快捷键"
  }
  public var directShortcutCount: Int {
    displayedConfiguration.bindings.values.filter { $0.directHotkey != nil }.count
  }
  public var hasPendingDirectChanges: Bool {
    guard let draft = editingSession?.draft else { return false }
    guard draft.directModeEnabled == configuration.directModeEnabled else { return true }
    let current = Dictionary(uniqueKeysWithValues: configuration.bindings.values.compactMap {
      record in record.directHotkey.map { (record.id, $0) }
    })
    let pending = Dictionary(uniqueKeysWithValues: draft.bindings.values.compactMap {
      record in record.directHotkey.map { (record.id, $0) }
    })
    return current != pending
  }
  public var draftValidationMessage: String? {
    guard let draft = editingSession?.draft else { return nil }
    let directRecords = draft.bindings.values.filter { $0.directHotkey != nil }
    let groups = Dictionary(grouping: directRecords) { $0.directHotkey! }
    if let duplicate = groups.first(where: { $0.value.count > 1 }) {
      let names = duplicate.value.prefix(2).map(privacySafeDisplayName(for:))
      return "\(names.joined(separator: " 与 ")) 使用了相同的全局快捷键 \(hotkeyDisplayName(duplicate.key))，请为其中一个重新录制。"
    }
    if let record = directRecords.first(where: { $0.directHotkey == draft.panelHotkey }) {
      return "\(privacySafeDisplayName(for: record)) 的全局快捷键 \(hotkeyDisplayName(draft.panelHotkey)) 与面板唤出组合重复，请重新录制。"
    }
    do {
      try ConfigurationValidator.validate(draft)
      return nil
    } catch {
      return error.localizedDescription
    }
  }
  public var canCommitEditing: Bool {
    hasEditingChanges && draftValidationMessage == nil && !isCommitting
  }

  private let registrar: any HotkeyRegistering
  private let repository: any ConfigurationRepositoryProtocol
  private let bookmarkResolver: any BookmarkResolving
  private let opener: any WorkspaceOpening
  private let lifecycle: HotkeyLifecycle
  private let bookmarkPolicy: BookmarkPolicy
  private let eventSink: any LauncherEventSink
  private let diagnosticsSink: any LauncherDiagnosticsSink
  private let initialPanelHotkey: HotkeyDefinition?
  private let keyLabelProvider: (any KeyLabelProviding)?
  private let presentsRepairUIOnDirectFailure: Bool
  private let targetPicker: any TargetPickerPresenting
  private let feedbackPresenter: any LauncherFeedbackPresenting
  private let panelPresenterFactory: LauncherPanelPresenterFactory?
  private let uiPreferencesStore: any LauncherUIPreferencesStoring
  public let launcherTheme: LauncherTheme
  public let applicationCatalog: any InstalledApplicationCataloging
  public let websiteIconProvider: any WebsiteIconProviding
  private let websiteIconImagePicker: any WebsiteIconImagePickerPresenting
  private let ownerLease: HotkeyOwnerLease
  private let ownerToken = UUID()
  private var ownsHotkeyLease = false
  private var registeredHotkeyIDs: Set<HotkeyID> = []
  private var configurationTransactionWaiters: [CheckedContinuation<Void, Never>] = []
  private enum LifecycleOperation { case idle, starting, stopping }
  private struct LifecycleOperationWaiter {
    let operation: LifecycleOperation
    let continuation: CheckedContinuation<Void, Never>
  }
  private var lifecycleOperation: LifecycleOperation = .idle
  private var lifecycleOperationWaiters: [LifecycleOperationWaiter] = []
  /// Invalidates accepted-but-not-yet-executed callbacks across stop/start.
  /// Configuration revisions cannot serve this purpose because an old direct
  /// route is intentionally allowed to execute its frozen target while a save
  /// is pending in the same lifecycle.
  private var lifecycleGeneration: UInt64 = 0
  private var releaseGate = ReleaseGate()
  private let panelInputPolicy = PanelInputPolicy()
  private var panelPresenter: (any LauncherPanelPresenting)?
  private var keyLabelCancellable: AnyCancellable?
  private var lastLoadResult: ConfigurationLoadResult?
  private var hotkeyRecorderSessionIDs: Set<UUID> = []
  private var recorderSuspendedHotkeys: [HotkeyID: HotkeyDefinition]?
  private var recorderSuspendedConflictKeyCodes: Set<UInt16> = []
  private var isRecorderIsolationTransitioning = false
  private var recorderIsolationWaiters: [CheckedContinuation<Void, Never>] = []
  /// Registrations created or rerouted for an unpersisted candidate must not
  /// reach the committed configuration. Unchanged registrations are left out
  /// of this set so they can continue to execute the last committed meaning
  /// while repository I/O is suspended.
  private var transactionSuppressedHotkeyIDs: Set<HotkeyID> = []
  private var feedbackDismissTask: Task<Void, Never>?
  private var feedbackQueue: [LauncherFeedbackEvent] = []
  private var uiPreferencesRevision: UInt64 = 0
  private var applicationPrewarmTask: Task<Void, Never>?
  private var websiteIconCleanupTasks: [BindingID: Task<Void, Never>] = [:]
  private var websiteIconCleanupGenerations: [BindingID: UUID] = [:]
  /// Deterministic scheduling seam used only by component tests that need to
  /// hold an accepted direct-hotkey callback across a configuration publication.
  var directExecutionBarrierForTesting: (@MainActor () async -> Void)?

  public convenience init(storageDirectory: URL) {
    self.init(hostConfiguration: ShortcutLauncherHostConfiguration(storageDirectory: storageDirectory))
  }

  public convenience init(
    hostConfiguration: ShortcutLauncherHostConfiguration,
    uiConfiguration: ShortcutLauncherUIConfiguration = ShortcutLauncherUIConfiguration()
  ) {
    self.init(
      registrar: CarbonHotkeyRegistrar(),
      repository: ConfigurationRepository(
        storageDirectory: hostConfiguration.storageDirectory
      ),
      bookmarkResolver: FoundationBookmarkResolver(),
      opener: NSWorkspaceTargetOpener(),
      bookmarkPolicy: hostConfiguration.bookmarkPolicy,
      eventSink: hostConfiguration.eventSink,
      diagnosticsSink: hostConfiguration.diagnosticsSink,
      initialPanelHotkey: hostConfiguration.initialPanelHotkey,
      ownerLease: .processShared,
      keyLabelProvider: SystemKeyLabelProvider(),
      presentsRepairUIOnDirectFailure: true,
      targetPicker: AppKitTargetPickerPresenter(),
      uiPreferencesStore: uiConfiguration.preferencesStore,
      launcherTheme: uiConfiguration.theme,
      applicationCatalog: uiConfiguration.applicationCatalog,
      websiteIconProvider: uiConfiguration.websiteIconProvider,
      websiteIconImagePicker: uiConfiguration.websiteIconImagePicker
    )
  }

  /// Compatibility initializer for existing hosts and deterministic tests.
  /// Production code should prefer the repository initializer or
  /// `init(hostConfiguration:)` so file I/O runs outside MainActor.
  public convenience init(
    registrar: any HotkeyRegistering,
    store: any ConfigurationStoring,
    bookmarkResolver: any BookmarkResolving,
    opener: any WorkspaceOpening,
    bookmarkPolicy: BookmarkPolicy = .securityScopedWhenAvailable,
    eventSink: any LauncherEventSink = NoopLauncherEventSink(),
    diagnosticsSink: any LauncherDiagnosticsSink = NoopLauncherDiagnosticsSink(),
    initialPanelHotkey: HotkeyDefinition? = nil,
    ownerLease: HotkeyOwnerLease = .processShared,
    keyLabelProvider: (any KeyLabelProviding)? = nil,
    presentsRepairUIOnDirectFailure: Bool = false,
    targetPicker: any TargetPickerPresenting = AppKitTargetPickerPresenter(),
    feedbackPresenter: any LauncherFeedbackPresenting = NoopLauncherFeedbackPresenter(),
    panelPresenterFactory: LauncherPanelPresenterFactory? = nil,
    uiPreferencesStore: (any LauncherUIPreferencesStoring)? = nil,
    launcherTheme: LauncherTheme = .standard,
    applicationCatalog: any InstalledApplicationCataloging = EmptyInstalledApplicationCatalog(),
    websiteIconProvider: any WebsiteIconProviding = EmptyWebsiteIconProvider(),
    websiteIconImagePicker: any WebsiteIconImagePickerPresenting = AppKitWebsiteIconImagePicker()
  ) {
    self.init(
      registrar: registrar,
      repository: ConfigurationStoreRepositoryAdapter(store: store),
      bookmarkResolver: bookmarkResolver,
      opener: opener,
      bookmarkPolicy: bookmarkPolicy,
      eventSink: eventSink,
      diagnosticsSink: diagnosticsSink,
      initialPanelHotkey: initialPanelHotkey,
      ownerLease: ownerLease,
      keyLabelProvider: keyLabelProvider,
      presentsRepairUIOnDirectFailure: presentsRepairUIOnDirectFailure,
      targetPicker: targetPicker,
      feedbackPresenter: feedbackPresenter,
      panelPresenterFactory: panelPresenterFactory,
      uiPreferencesStore: uiPreferencesStore,
      launcherTheme: launcherTheme,
      applicationCatalog: applicationCatalog,
      websiteIconProvider: websiteIconProvider,
      websiteIconImagePicker: websiteIconImagePicker
    )
  }

  public init(
    registrar: any HotkeyRegistering,
    repository: any ConfigurationRepositoryProtocol,
    bookmarkResolver: any BookmarkResolving,
    opener: any WorkspaceOpening,
    bookmarkPolicy: BookmarkPolicy = .securityScopedWhenAvailable,
    eventSink: any LauncherEventSink = NoopLauncherEventSink(),
    diagnosticsSink: any LauncherDiagnosticsSink = NoopLauncherDiagnosticsSink(),
    initialPanelHotkey: HotkeyDefinition? = nil,
    ownerLease: HotkeyOwnerLease = .processShared,
    keyLabelProvider: (any KeyLabelProviding)? = nil,
    presentsRepairUIOnDirectFailure: Bool = false,
    targetPicker: any TargetPickerPresenting = AppKitTargetPickerPresenter(),
    feedbackPresenter: any LauncherFeedbackPresenting = NoopLauncherFeedbackPresenter(),
    panelPresenterFactory: LauncherPanelPresenterFactory? = nil,
    uiPreferencesStore: (any LauncherUIPreferencesStoring)? = nil,
    launcherTheme: LauncherTheme = .standard,
    applicationCatalog: any InstalledApplicationCataloging = EmptyInstalledApplicationCatalog(),
    websiteIconProvider: any WebsiteIconProviding = EmptyWebsiteIconProvider(),
    websiteIconImagePicker: any WebsiteIconImagePickerPresenting = AppKitWebsiteIconImagePicker()
  ) {
    self.registrar = registrar
    self.repository = repository
    self.bookmarkResolver = bookmarkResolver
    self.opener = opener
    self.bookmarkPolicy = bookmarkPolicy
    self.eventSink = eventSink
    self.diagnosticsSink = diagnosticsSink
    self.initialPanelHotkey = initialPanelHotkey
    self.ownerLease = ownerLease
    self.keyLabelProvider = keyLabelProvider
    self.presentsRepairUIOnDirectFailure = presentsRepairUIOnDirectFailure
    self.targetPicker = targetPicker
    self.feedbackPresenter = feedbackPresenter
    self.panelPresenterFactory = panelPresenterFactory
    self.uiPreferencesStore = uiPreferencesStore ?? LauncherUIPreferencesRepository(
      storageDirectory: repository.configurationURL.deletingLastPathComponent()
    )
    self.launcherTheme = launcherTheme
    self.applicationCatalog = applicationCatalog
    self.websiteIconProvider = websiteIconProvider
    self.websiteIconImagePicker = websiteIconImagePicker
    keyLabelSnapshot = keyLabelProvider?.snapshot ?? .fallback()
    lifecycle = HotkeyLifecycle(registrar: registrar)
  }

  public func start() async throws {
    await acquireLifecycleOperation(.starting)
    defer { finishLifecycleOperation() }
    if isCommitting {
      await waitForConfigurationTransaction()
    }
    guard lifecycle.state == .stopped else { return }
    guard ownerLease.acquire(token: ownerToken) else {
      throw LauncherError.moduleAlreadyActive
    }
    ownsHotkeyLease = true
    advanceLifecycleGeneration()
    startKeyLabelObservation()

    do {
      lastLoadResult = nil
      let loadResult = try await repository.load()
      lastLoadResult = loadResult
      configuration = loadResult.configuration
      configurationRevision &+= 1
      do {
        let preferenceResult = try await uiPreferencesStore.load()
        uiPreferences = preferenceResult.preferences
        uiPreferencesRevision &+= 1
        if preferenceResult.recoveredFromBackup || preferenceResult.recoveredUsingDefaults {
          diagnosticsSink.record(code: "ui_preferences_recovered", metadata: [:])
        }
      } catch {
        uiPreferences = .defaults
        uiPreferencesRevision &+= 1
        diagnosticsSink.record(code: "ui_preferences_unavailable", metadata: [:])
      }
      if let iconManager = websiteIconProvider as? any WebsiteIconManaging {
        await iconManager.setOnlineFetchingEnabled(uiPreferences.onlineWebsiteIconsEnabled)
      }
      if loadResult.wasFirstRun, let initialPanelHotkey {
        let loadedConfiguration = configuration
        var initialConfiguration = loadedConfiguration
        initialConfiguration.panelHotkey = initialPanelHotkey
        try ConfigurationValidator.validate(initialConfiguration)
        try await persistCandidate(
          initialConfiguration,
          restoring: loadedConfiguration
        )
        configuration = initialConfiguration
      }
      try ConfigurationValidator.validate(configuration)
      if loadResult.recoveredFromBackup {
        statusText = LauncherError.configurationRecovered.localizedDescription
        eventSink.receive(LauncherEvent(
          name: .configurationRecovered,
          resultCode: "backup",
          configurationRevision: configurationRevision
        ))
      }
      if loadResult.migrated {
        eventSink.receive(LauncherEvent(
          name: .configurationMigrated,
          resultCode: "schema-v3",
          configurationRevision: configurationRevision
        ))
      }

      try await lifecycle.start(panelHotkey: configuration.panelHotkey) { [weak self] id in
        guard let self else { return }
        guard !self.transactionSuppressedHotkeyIDs.contains(id) else {
          self.diagnosticsSink.record(code: "hotkey_callback_suppressed_during_commit", metadata: [:])
          return
        }
        switch id {
        case .panel:
          guard self.hotkeyRecorderSessionIDs.isEmpty, !self.isCommitting else {
            self.diagnosticsSink.record(
              code: "panel_hotkey_ignored_during_transaction",
              metadata: [:]
            )
            return
          }
          self.logger.notice("panel_hotkey_received")
          self.presentPanel(invokedByHotkey: true)
        case .direct(let bindingID):
          guard self.hotkeyRecorderSessionIDs.isEmpty else { return }
          guard let keyCode = self.configuration.keyCode(for: bindingID),
            let record = self.configuration.bindings[keyCode]
          else {
            self.diagnosticsSink.record(code: "direct_hotkey_route_missing", metadata: [:])
            return
          }
          // Freeze the committed meaning at callback acceptance time. The
          // asynchronous execution task may not run until after a configuration
          // commit publishes a new target for the same BindingID.
          let executionRevision = self.configurationRevision
          let executionLifecycleGeneration = self.lifecycleGeneration
          Task { @MainActor [weak self] in
            guard let self else { return }
            await self.directExecutionBarrierForTesting?()
            guard
              self.lifecycle.state == .started,
              self.lifecycleOperation == .idle,
              self.lifecycleGeneration == executionLifecycleGeneration
            else { return }
            _ = await self.performExecution(
              record: record,
              keyCode: keyCode,
              source: .directHotkey,
              executionConfigurationRevision: executionRevision
            )
          }
        }
      }
      registeredHotkeyIDs = [.panel]
      runtimeIssueCodes.remove(.panelHotkeyUnavailable)
      runtimeIssueCodes.remove(.registrationRecoveryIncomplete)
      runtimeIssueCodes.remove(.configurationRollbackFailed)
      runtimeIssueCodes.remove(.moduleUnavailable)

      if configuration.directModeEnabled { await registerAllDirectHotkeys() }
      if directConflictKeyCodes.isEmpty {
        statusText = "已启动。按 \(activePanelHotkeyDisplayName) 唤出面板。"
      } else {
        statusText = "已启动；有 \(directConflictKeyCodes.count) 个全局快捷键被占用。"
      }
      let applicationCatalog = applicationCatalog
      applicationPrewarmTask?.cancel()
      applicationPrewarmTask = Task(priority: .utility) {
        _ = await applicationCatalog.prewarm(forceRefresh: false)
      }
      eventSink.receive(LauncherEvent(
        name: .moduleStarted,
        resultCode: "success",
        configurationRevision: configurationRevision
      ))
    } catch {
      stopKeyLabelObservation()
      if ownsHotkeyLease {
        ownerLease.release(token: ownerToken)
        ownsHotkeyLease = false
      }
      throw error
    }
  }

  public func stop() async {
    await acquireLifecycleOperation(.stopping)
    defer { finishLifecycleOperation() }
    advanceLifecycleGeneration()
    if isCommitting {
      statusText = "正在完成当前保存，随后暂停所有快捷键。"
      await waitForConfigurationTransaction()
    }
    dismissPanel()
    await lifecycle.stop()
    stopKeyLabelObservation()
    panelPresenter?.invalidate()
    panelPresenter = nil
    if let bindingID = repairPrompt?.bindingID {
      feedbackPresenter.dismiss(bindingID: bindingID)
    }
    repairPrompt = nil
    feedbackDismissTask?.cancel()
    feedbackDismissTask = nil
    feedbackEvent = nil
    feedbackQueue.removeAll()
    busyKeyCodes.removeAll()
    applicationPrewarmTask?.cancel()
    applicationPrewarmTask = nil
    await applicationCatalog.invalidate()
    websiteIconCleanupTasks.values.forEach { $0.cancel() }
    websiteIconCleanupTasks.removeAll()
    websiteIconCleanupGenerations.removeAll()
    await websiteIconProvider.cancelAll()
    hotkeyRecorderSessionIDs.removeAll()
    recorderSuspendedHotkeys = nil
    recorderSuspendedConflictKeyCodes.removeAll()
    isHotkeyRecorderReady = false
    registeredHotkeyIDs.removeAll()
    directConflictKeyCodes.removeAll()
    runtimeIssueCodes.removeAll()
    if ownsHotkeyLease {
      ownerLease.release(token: ownerToken)
      ownsHotkeyLease = false
    }
    statusText = isEditing
      ? "已暂停所有快捷键；未保存草稿仍保留。"
      : "已停止，快捷键已释放。"
  }

  public func bindingRecord(for keyCode: UInt16) -> BindingRecord? {
    displayedConfiguration.bindings[keyCode]
  }

  public func bindingPresentation(for keyCode: UInt16) -> BindingPresentation {
    BindingStateResolver.resolve(slotKeyCode: keyCode, from: bindingStateInputSnapshot)
  }

  public func keyLabel(for keyCode: UInt16) -> String {
    keyLabelSnapshot.label(for: keyCode)
  }

  public func hotkeyDisplayName(_ hotkey: HotkeyDefinition) -> String {
    keyLabelSnapshot.displayName(for: hotkey)
  }

  private func startKeyLabelObservation() {
    guard let keyLabelProvider else { return }
    keyLabelCancellable?.cancel()
    keyLabelCancellable = nil
    if let provider = keyLabelProvider as? SystemKeyLabelProvider {
      keyLabelCancellable = provider.$snapshot
        .dropFirst()
        .sink { [weak self] snapshot in
          self?.keyLabelSnapshot = snapshot
        }
    }
    keyLabelProvider.startObserving()
    keyLabelProvider.refresh()
    keyLabelSnapshot = keyLabelProvider.snapshot
  }

  private func stopKeyLabelObservation() {
    keyLabelProvider?.stopObserving()
    keyLabelCancellable?.cancel()
    keyLabelCancellable = nil
  }

  public var registrationLedgerSnapshot: RegistrationLedgerSnapshot {
    let raw = rawRegistrationLedgerSnapshot
    return RegistrationLedgerSnapshot(
      registeredBindingIDs: Set(raw.registeredBindingIDs.map(\.hostSafeProjection)),
      conflictedBindingIDs: Set(raw.conflictedBindingIDs.map(\.hostSafeProjection)),
      directHotkeysPaused: raw.directHotkeysPaused
    )
  }

  private var rawRegistrationLedgerSnapshot: RegistrationLedgerSnapshot {
    let registeredBindingIDs = Set(registeredHotkeyIDs.compactMap { id -> BindingID? in
      guard case .direct(let bindingID) = id else { return nil }
      return bindingID
    })
    let conflictedBindingIDs = Set(directConflictKeyCodes.compactMap {
      configuration.bindings[$0]?.id
    })
    return RegistrationLedgerSnapshot(
      registeredBindingIDs: registeredBindingIDs,
      conflictedBindingIDs: conflictedBindingIDs,
      directHotkeysPaused: !configuration.directModeEnabled
        || lifecycle.state != .started
        || lifecycleOperation != .idle
        || recorderSuspendedHotkeys != nil
    )
  }

  /// Temporarily removes the module's Carbon registrations while a local
  /// first-responder recorder is available. This prevents an already-registered
  /// panel or direct combination from winning before the recorder sees it.
  @discardableResult
  func beginHotkeyRecorderSession(_ sessionID: UUID) async -> Bool {
    let inserted = hotkeyRecorderSessionIDs.insert(sessionID).inserted
    guard inserted else {
      return hotkeyRecorderSessionIDs.contains(sessionID)
        && isHotkeyRecorderReady
        && !isRecorderIsolationTransitioning
    }
    isHotkeyRecorderReady = false

    guard hotkeyRecorderSessionIDs.count == 1 else {
      isHotkeyRecorderReady = recorderSuspendedHotkeys != nil
        && !isRecorderIsolationTransitioning
      return isHotkeyRecorderReady
    }
    guard lifecycle.state == .started,
      lifecycleOperation == .idle,
      !isCommitting
    else {
      // A stopped module has no global registrations to intercept local input.
      isHotkeyRecorderReady = lifecycle.state == .stopped
      return isHotkeyRecorderReady
    }

    let actualHotkeys = desiredHotkeys(for: configuration).filter {
      registeredHotkeyIDs.contains($0.key)
    }
    isRecorderIsolationTransitioning = true
    recorderSuspendedHotkeys = actualHotkeys
    recorderSuspendedConflictKeyCodes = directConflictKeyCodes
    await registrar.unregisterAll()

    guard lifecycle.state == .started, lifecycleOperation == .idle else {
      recorderSuspendedHotkeys = nil
      recorderSuspendedConflictKeyCodes.removeAll()
      registeredHotkeyIDs.removeAll()
      finishRecorderIsolationTransition()
      return false
    }
    registeredHotkeyIDs.removeAll()

    // The sheet may have closed while an injected registrar was suspended.
    if hotkeyRecorderSessionIDs.isEmpty {
      await restoreHotkeysAfterRecorderIfNeeded()
    } else {
      isHotkeyRecorderReady = true
    }
    finishRecorderIsolationTransition()
    return isHotkeyRecorderReady
  }

  func endHotkeyRecorderSession(_ sessionID: UUID) async {
    guard hotkeyRecorderSessionIDs.remove(sessionID) != nil else {
      await waitForRecorderIsolationToSettleIfNeeded()
      return
    }
    guard hotkeyRecorderSessionIDs.isEmpty else { return }
    isHotkeyRecorderReady = false
    if isRecorderIsolationTransitioning {
      await withCheckedContinuation { continuation in
        recorderIsolationWaiters.append(continuation)
      }
      return
    }
    await restoreHotkeysAfterRecorderIfNeeded()
  }

  private func waitForRecorderIsolationToSettleIfNeeded() async {
    if isRecorderIsolationTransitioning {
      await withCheckedContinuation { continuation in
        recorderIsolationWaiters.append(continuation)
      }
    }
    if hotkeyRecorderSessionIDs.isEmpty,
      recorderSuspendedHotkeys != nil,
      isCommitting
    {
      await waitForConfigurationTransaction()
    }
  }

  private func finishRecorderIsolationTransition() {
    isRecorderIsolationTransitioning = false
    let waiters = recorderIsolationWaiters
    recorderIsolationWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  public func binding(for keyCode: UInt16) -> LaunchTarget? {
    bindingRecord(for: keyCode)?.target
  }

  public func directHotkey(for keyCode: UInt16) -> HotkeyDefinition? {
    bindingRecord(for: keyCode)?.directHotkey
  }

  func requiredRepairTargetKind(for keyCode: UInt16) -> LaunchTargetKind? {
    guard invalidKeyCodes.contains(keyCode) else { return nil }
    return configuration.bindings[keyCode]?.target.kind
  }

  public func isDisplayedBindingInvalid(_ record: BindingRecord?) -> Bool {
    guard let record,
      let activeKeyCode = configuration.keyCode(for: record.id),
      configuration.bindings[activeKeyCode]?.target == record.target
    else { return false }
    return invalidKeyCodes.contains(activeKeyCode)
  }

  public func displayedBindingHasDirectConflict(_ record: BindingRecord?) -> Bool {
    guard let record,
      let activeKeyCode = configuration.keyCode(for: record.id),
      configuration.bindings[activeKeyCode]?.directHotkey == record.directHotkey
    else { return false }
    return directConflictKeyCodes.contains(activeKeyCode)
  }

  public func presentPanel() {
    presentPanel(invokedByHotkey: false)
  }

  public func presentPanel(invokedByHotkey: Bool) {
    guard !isCommitting else {
      diagnosticsSink.record(code: "panel_presentation_ignored_during_transaction", metadata: [:])
      return
    }
    guard lifecycle.state == .started, lifecycleOperation == .idle else {
      statusText = "快捷启动模块尚未运行，无法打开面板。"
      return
    }
    let panelPresenter = resolvedPanelPresenter()
    if invokedByHotkey, panelPresenter.isVisible {
      dismissPanel()
      return
    }
    // Every new presentation starts at the complete 38-key grid. A quick
    // binding popover belongs to one visible panel session and must never be
    // restored as an implicit first screen on the next invocation.
    quickBindingSession = nil
    if bindingRequestKeyCode != nil {
      closeBindingEditor()
    }
    if invokedByHotkey {
      releaseGate.begin(
        invocationKeyCode: configuration.panelHotkey.keyCode,
        modifiers: configuration.panelHotkey.modifiers
      )
      logger.notice("release_gate_waiting")
    } else {
      releaseGate.armImmediately()
    }
    isArmed = releaseGate.isArmed
    statusText = armedStatusText
    panelPresenter.showOnCurrentScreen()
    if invokedByHotkey {
      synchronizeReleaseGateWithSystemKeyboardState()
      DispatchQueue.main.async { [weak self] in
        self?.synchronizeReleaseGateWithSystemKeyboardState()
      }
    }
  }

  public func dismissPanel() {
    guard !isCommitting else {
      diagnosticsSink.record(code: "panel_dismiss_ignored_during_transaction", metadata: [:])
      return
    }
    panelPresenter?.dismiss()
    releaseGate.reset()
    isArmed = false
    quickBindingSession = nil
    closeBindingEditor()
  }

  public func beginEditing() {
    guard allowDraftMutation() else { return }
    guard editingSession == nil else { return }
    editingSession = BindingEditSession(configuration: configuration)
    singleBindingTransaction = nil
    bindingRequestKeyCode = nil
    statusText = "编辑模式：修改只保存在草稿中。"
  }

  public func cancelEditing() {
    guard allowDraftMutation() else { return }
    guard editingSession != nil else { return }
    editingSession = nil
    singleBindingTransaction = nil
    bindingRequestKeyCode = nil
    errorMessage = nil
    cancelConfirmationRequested = false
    statusText = "已取消编辑，原配置未改变。"
  }

  public func requestCancelEditing() {
    guard allowDraftMutation() else { return }
    if hasEditingChanges {
      cancelConfirmationRequested = true
    } else {
      cancelEditing()
    }
  }

  public func commitEditing() async {
    _ = await commitEditingWithResult()
  }

  public func commit(_ request: LauncherCommitRequest) async -> LauncherCommitResult {
    guard request.expectedConfigurationRevision == configurationRevision else {
      return .rejected(reason: .staleRevision)
    }
    guard request.candidateConfiguration != configuration else {
      return .rejected(reason: .noChanges)
    }
    guard editingSession == nil, !isCommitting else {
      return .rejected(reason: .transactionInProgress)
    }
    guard hotkeyRecorderSessionIDs.isEmpty,
      recorderSuspendedHotkeys == nil,
      !isRecorderIsolationTransitioning
    else {
      return .rejected(reason: .transactionInProgress)
    }
    guard lifecycleOperation == .idle else {
      return .rejected(
        reason: lifecycleOperation == .stopping ? .moduleStopping : .moduleUnavailable
      )
    }
    do {
      try ConfigurationValidator.validate(request.candidateConfiguration)
    } catch {
      return .validationFailed([
        validationIssue(for: error, configuration: request.candidateConfiguration)
      ])
    }

    isCommitting = true
    defer { finishConfigurationTransaction() }
    do {
      try await applyConfiguration(request.candidateConfiguration)
      statusText = "宿主配置已保存并应用。"
      eventSink.receive(LauncherEvent(
        name: .editCommitted,
        resultCode: "host-success",
        configurationRevision: configurationRevision
      ))
      let enabled = registeredHotkeyIDs.compactMap { id -> BindingID? in
        guard case .direct(let bindingID) = id else { return nil }
        return bindingID.hostSafeProjection
      }.sorted { $0.rawValue < $1.rawValue }
      return .committed(configurationRevision: configurationRevision, enabled: enabled)
    } catch {
      report(error, prefix: "无法应用宿主配置")
      return commitFailureResult(for: error, configuration: request.candidateConfiguration)
    }
  }

  @discardableResult
  public func commitEditingWithResult() async -> LauncherCommitResult {
    guard !isCommitting else {
      statusText = "已有配置正在保存，请等待当前操作完成。"
      return .rejected(reason: .transactionInProgress)
    }
    guard lifecycleOperation == .idle else {
      statusText = lifecycleOperation == .stopping
        ? "正在暂停快捷键；当前草稿仍保留。"
        : "快捷键生命周期正在切换，请稍候再保存。"
      return .rejected(
        reason: lifecycleOperation == .stopping ? .moduleStopping : .moduleUnavailable
      )
    }
    guard hotkeyRecorderSessionIDs.isEmpty,
      recorderSuspendedHotkeys == nil,
      !isRecorderIsolationTransitioning
    else {
      statusText = "请先完成或退出快捷键录制，再保存当前修改。"
      return .rejected(reason: .transactionInProgress)
    }
    guard let session = editingSession else {
      statusText = "没有需要保存的修改。"
      return .rejected(reason: .noChanges)
    }
    let committedSingleTransaction = singleBindingTransaction
    let candidate = committedSingleTransaction?.merging(into: configuration) ?? session.draft
    let hasChanges = committedSingleTransaction?.hasChanges ?? session.hasChanges
    guard hasChanges, candidate != configuration else {
      editingSession = nil
      singleBindingTransaction = nil
      bindingRequestKeyCode = nil
      statusText = "没有需要保存的修改。"
      return .rejected(reason: .noChanges)
    }

    do {
      try ConfigurationValidator.validate(candidate)
    } catch {
      report(error, prefix: "无法完成编辑")
      return .validationFailed([validationIssue(for: error, configuration: candidate)])
    }

    isCommitting = true
    defer { finishConfigurationTransaction() }
    do {
      let committedSingleSlot = committedSingleTransaction?.slotKeyCode
      try await applyConfiguration(candidate)
      editingSession = nil
      singleBindingTransaction = nil
      bindingRequestKeyCode = nil
      let directRecords = candidate.bindings.values.filter { $0.directHotkey != nil }
      let committedSingleRecord = committedSingleSlot.flatMap {
        candidate.bindings[$0]
      }
      if !directConflictKeyCodes.isEmpty {
        let enabledCount = registeredHotkeyIDs.reduce(into: 0) { count, id in
          if case .direct = id { count += 1 }
        }
        statusText = "修改已保存；\(enabledCount) 个全局快捷键已启用，\(directConflictKeyCodes.count) 个仍有冲突，可逐项重试。"
      } else if candidate.directModeEnabled,
        let record = committedSingleRecord,
        let hotkey = record.directHotkey,
        registeredHotkeyIDs.contains(.direct(bindingID: record.id))
      {
        statusText = "已保存：\(privacySafeDisplayName(for: record)) 的 \(hotkeyDisplayName(hotkey)) 已启用；现在可切到其他应用测试。"
      } else if candidate.directModeEnabled, !directRecords.isEmpty {
        statusText = "已保存并启用 \(directRecords.count) 个全局快捷键，可在任何应用中直接使用。"
      } else if !directRecords.isEmpty {
        statusText = "修改已保存；\(directRecords.count) 个全局快捷键目前处于暂停状态。"
      } else {
        statusText = "修改已保存。按 \(candidate.panelHotkey.displayName) 唤出面板，释放组合键后再按目标键。"
      }
      eventSink.receive(LauncherEvent(
        name: .editCommitted,
        bindingID: committedSingleRecord?.id,
        targetKind: committedSingleRecord?.target.kind,
        resultCode: "success",
        configurationRevision: configurationRevision
      ))
      let enabled = registeredHotkeyIDs.compactMap { id -> BindingID? in
        guard case .direct(let bindingID) = id else { return nil }
        return bindingID.hostSafeProjection
      }.sorted { $0.rawValue < $1.rawValue }
      return .committed(configurationRevision: configurationRevision, enabled: enabled)
    } catch {
      report(error, prefix: "无法完成编辑")
      return commitFailureResult(for: error, configuration: candidate)
    }
  }

  public func requestBinding(for keyCode: UInt16) {
    guard allowDraftMutation() else { return }
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else { return }
    guard allowsSingleSlotMutation(keyCode) else { return }
    if editingSession == nil {
      beginSingleBindingEditing(for: keyCode)
    }
    bindingRequestKeyCode = keyCode
  }

  /// Opens the ordinary binding experience without allocating an edit draft
  /// and without entering the full hotkey recorder. The selected slot already
  /// supplies the shortcut's primary key.
  @discardableResult
  public func requestQuickBinding(for keyCode: UInt16) -> QuickBindingSession? {
    guard allowDraftMutation() else { return nil }
    guard editingSession == nil else {
      statusText = "请先保存或取消当前高级编辑。"
      return nil
    }
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else { return nil }
    if let activeSession = quickBindingSession,
      activeSession.keyCode == keyCode,
      activeSession.expectedConfigurationRevision == configurationRevision
    {
      return activeSession
    }
    errorMessage = nil
    let existingHotkey = configuration.bindings[keyCode]?.directHotkey
    let session = QuickBindingSession(
      keyCode: keyCode,
      expectedConfigurationRevision: configurationRevision,
      chooserSnapshot: QuickBindingChooserSnapshot(
        selectedModifiers: existingHotkey?.modifiers ?? [.control],
        usesPanelOnly: configuration.bindings[keyCode] != nil && existingHotkey == nil
      )
    )
    quickBindingSession = session
    statusText = configuration.bindings[keyCode] == nil
      ? "选择要绑定到 \(keyLabel(for: keyCode)) 的目标。"
      : "选择新目标；保存后仍使用当前键位。"
    return session
  }

  public func isBusy(_ keyCode: UInt16) -> Bool {
    busyKeyCodes.contains(keyCode)
  }

  public func updateQuickBindingChooserSnapshot(
    _ snapshot: QuickBindingChooserSnapshot,
    sessionID: UUID
  ) {
    guard let session = quickBindingSession,
      session.id == sessionID,
      session.phase == .choosingTarget
    else { return }
    quickBindingSession = QuickBindingSession(
      id: session.id,
      presentationID: session.presentationID,
      keyCode: session.keyCode,
      expectedConfigurationRevision: session.expectedConfigurationRevision,
      phase: session.phase,
      pendingTarget: session.pendingTarget,
      chooserSnapshot: snapshot
    )
  }

  public func closeQuickBinding(sessionID: UUID? = nil) {
    guard !isCommitting else { return }
    if let sessionID, quickBindingSession?.id != sessionID { return }
    quickBindingSession = nil
    errorMessage = nil
  }

  public func dismissFeedback() {
    feedbackDismissTask?.cancel()
    feedbackDismissTask = nil
    feedbackEvent = nil
    presentNextFeedbackIfNeeded()
  }

  public func undo(_ token: LauncherUndoToken) async -> LauncherCommitResult {
    guard feedbackEvent?.undoToken?.id == token.id else {
      return .rejected(reason: .staleRevision)
    }
    feedbackDismissTask?.cancel()
    feedbackDismissTask = nil
    feedbackEvent = nil
    feedbackQueue.removeAll()
    guard configurationRevision == token.expectedAfterRevision else {
      publishFeedback(
        kind: .warning,
        message: "配置已经发生变化，不能覆盖较新的修改。",
        slotKeyCode: token.slotKeyCode
      )
      return .rejected(reason: .staleRevision)
    }

    if let keyCode = token.slotKeyCode { busyKeyCodes.insert(keyCode) }
    defer {
      if let keyCode = token.slotKeyCode { busyKeyCodes.remove(keyCode) }
    }
    let result = await commit(LauncherCommitRequest(
      expectedConfigurationRevision: token.expectedAfterRevision,
      candidateConfiguration: token.before
    ))
    if case .committed = result {
      publishFeedback(
        kind: .information,
        message: "已撤销上一步操作。",
        slotKeyCode: token.slotKeyCode
      )
    } else {
      publishFeedback(
        kind: .warning,
        message: "未能撤销；当前配置保持不变。",
        slotKeyCode: token.slotKeyCode
      )
    }
    return result
  }

  public func suggestedModifierSets(for keyCode: UInt16) -> [ModifierSet] {
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else { return [] }
    let candidates: [ModifierSet] = [
      [.option],
      [.control, .option],
      [.command, .option],
      [.control, .shift],
      [.command, .shift],
    ]
    let occupied = Set(configuration.bindings.values.compactMap { record -> HotkeyDefinition? in
      guard record.physicalKeyCode != keyCode else { return nil }
      return record.directHotkey
    })
    return candidates.filter { modifiers in
      let hotkey = HotkeyDefinition(keyCode: keyCode, modifiers: modifiers)
      return hotkey != configuration.panelHotkey && !occupied.contains(hotkey)
    }
  }

  /// SwiftUI reports a transient popover dismissal when an `NSOpenPanel`
  /// becomes the active window. That presentation event must not be confused
  /// with the user closing the binding flow: only an idle chooser dismissal
  /// ends the business session.
  public func quickBindingPresentationDidDismiss(
    for keyCode: UInt16,
    sessionID: UUID,
    presentationID: UUID
  ) {
    guard let session = quickBindingSession,
      session.id == sessionID,
      session.presentationID == presentationID,
      session.keyCode == keyCode,
      session.phase == .choosingTarget
    else { return }
    closeQuickBinding(sessionID: sessionID)
  }

  /// Opens the system picker without mutating configuration. A selected URL is
  /// retained only in this ephemeral session, allowing an in-place retry even
  /// though AppKit temporarily dismisses the SwiftUI popover.
  public func selectQuickTarget(
    kind: LaunchTargetKind,
    for keyCode: UInt16,
    shortcutChoice: QuickBindingShortcutChoice = .defaultForNew,
    sessionID: UUID? = nil
  ) async throws -> URL? {
    guard kind != .web else { throw LauncherError.invalidURL }
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else {
      throw LauncherError.invalidConfiguration("绑定槽位无效")
    }
    guard let session = quickBindingSession,
      session.keyCode == keyCode,
      sessionID.map({ $0 == session.id }) ?? true
    else {
      throw LauncherError.invalidConfiguration("这个绑定窗口已经失效，请重新打开")
    }
    guard session.phase == .choosingTarget else {
      throw LauncherError.invalidConfiguration("已有目标选择正在进行，请稍候")
    }
    guard session.expectedConfigurationRevision == configurationRevision else {
      quickBindingSession = QuickBindingSession(
        id: session.id,
        presentationID: session.presentationID,
        keyCode: session.keyCode,
        expectedConfigurationRevision: configurationRevision,
        phase: .choosingTarget,
        pendingTarget: session.pendingTarget,
        chooserSnapshot: session.chooserSnapshot
      )
      errorMessage = "配置刚刚发生变化，请确认后重新选择目标。"
      statusText = errorMessage ?? "配置刚刚发生变化。"
      throw LauncherError.invalidConfiguration("配置刚刚发生变化，请重新确认")
    }

    quickBindingSession = QuickBindingSession(
      id: session.id,
      presentationID: session.presentationID,
      keyCode: session.keyCode,
      expectedConfigurationRevision: session.expectedConfigurationRevision,
      phase: .systemPicker,
      pendingTarget: session.pendingTarget,
      chooserSnapshot: session.chooserSnapshot
    )
    statusText = "正在选择要绑定到 \(keyLabel(for: keyCode)) 的\(kind.displayName)…"

    // Publish the hidden-popover phase before asking AppKit to attach its
    // sheet. This gives SwiftUI one run-loop turn to remove the transient
    // popover without destroying the quick-binding business session.
    await Task.yield()
    guard let activeSession = quickBindingSession,
      activeSession.id == session.id,
      activeSession.phase == .systemPicker
    else {
      throw LauncherError.invalidConfiguration("这个绑定窗口已经失效，请重新打开")
    }

    let selectedURL = await targetPicker.chooseTargetAsync(
      kind: kind,
      panelKeyLabel: keyLabel(for: keyCode),
      presentationWindow: panelPresenter?.targetPickerPresentationWindow
    )
    guard let resumedSession = quickBindingSession,
      resumedSession.id == session.id,
      resumedSession.keyCode == keyCode
    else {
      throw LauncherError.invalidConfiguration("这个绑定窗口已经失效，请重新打开")
    }
    guard let selectedURL else {
      quickBindingSession = QuickBindingSession(
        id: resumedSession.id,
        keyCode: resumedSession.keyCode,
        expectedConfigurationRevision: resumedSession.expectedConfigurationRevision,
        phase: .choosingTarget,
        pendingTarget: resumedSession.pendingTarget,
        chooserSnapshot: resumedSession.chooserSnapshot
      )
      errorMessage = nil
      statusText = "已取消选择，原绑定未改变。"
      return nil
    }

    let pendingTarget = QuickBindingPendingTarget(
      url: selectedURL,
      kind: kind,
      shortcutChoice: shortcutChoice
    )
    guard resumedSession.expectedConfigurationRevision == configurationRevision else {
      quickBindingSession = QuickBindingSession(
        id: resumedSession.id,
        keyCode: resumedSession.keyCode,
        expectedConfigurationRevision: configurationRevision,
        phase: .choosingTarget,
        pendingTarget: pendingTarget,
        chooserSnapshot: resumedSession.chooserSnapshot
      )
      errorMessage = "选择期间配置发生了变化；目标已保留，请确认后重试。"
      statusText = errorMessage ?? "选择期间配置发生了变化。"
      throw LauncherError.invalidConfiguration("配置刚刚发生变化，请重新确认")
    }

    quickBindingSession = QuickBindingSession(
      id: resumedSession.id,
      presentationID: resumedSession.presentationID,
      keyCode: resumedSession.keyCode,
      expectedConfigurationRevision: resumedSession.expectedConfigurationRevision,
      phase: .committing,
      pendingTarget: pendingTarget,
      chooserSnapshot: resumedSession.chooserSnapshot
    )
    return selectedURL
  }

  /// Selects a local target through the injected platform boundary and commits
  /// it immediately. `nil` means the user cancelled the system picker.
  public func quickChooseTarget(
    kind: LaunchTargetKind,
    for keyCode: UInt16,
    shortcutChoice: QuickBindingShortcutChoice,
    sessionID: UUID? = nil
  ) async throws -> LauncherCommitResult? {
    guard let url = try await selectQuickTarget(
      kind: kind,
      for: keyCode,
      shortcutChoice: shortcutChoice,
      sessionID: sessionID
    ) else {
      return nil
    }
    return try await quickBindTarget(
      url: url,
      kind: kind,
      to: keyCode,
      shortcutChoice: shortcutChoice,
      sessionID: sessionID
    )
  }

  /// Normalizes a web address and commits it through the same atomic path as
  /// every other quick target. Bare domains are accepted by the Core validator.
  public func quickBindWebURL(
    _ rawValue: String,
    to keyCode: UInt16,
    shortcutChoice: QuickBindingShortcutChoice,
    sessionID: UUID? = nil
  ) async throws -> LauncherCommitResult {
    let url = try WebURLValidator.normalize(rawValue)
    return try await quickBindTarget(
      url: url,
      kind: .web,
      to: keyCode,
      shortcutChoice: shortcutChoice,
      sessionID: sessionID
    )
  }

  /// Entry point shared by Finder/browser drops after the UI has resolved and,
  /// for an occupied slot, explicitly confirmed the replacement preview.
  public func bindDroppedTarget(
    url: URL,
    kind: LaunchTargetKind,
    to keyCode: UInt16
  ) async throws -> LauncherCommitResult {
    guard editingSession == nil else {
      return .rejected(reason: .transactionInProgress)
    }
    guard let session = requestQuickBinding(for: keyCode) else {
      return .rejected(reason: .transactionInProgress)
    }
    let choice: QuickBindingShortcutChoice = configuration.bindings[keyCode] == nil
      ? .defaultForNew
      : .preserveExisting
    return try await quickBindTarget(
      url: url,
      kind: kind,
      to: keyCode,
      shortcutChoice: choice,
      sessionID: session.id
    )
  }

  /// Creates a target and publishes one complete candidate. There is no
  /// separate preflight/save gap: `commit` retains the existing staged Carbon
  /// registration and repository rollback guarantees.
  public func quickBindTarget(
    url: URL,
    kind: LaunchTargetKind,
    to keyCode: UInt16,
    shortcutChoice: QuickBindingShortcutChoice,
    preferredDisplayName: String? = nil,
    sessionID: UUID? = nil
  ) async throws -> LauncherCommitResult {
    guard let session = quickBindingSession,
      session.keyCode == keyCode,
      sessionID.map({ $0 == session.id }) ?? true
    else {
      errorMessage = "这个绑定窗口已经失效，请重新打开。"
      return .rejected(reason: .staleRevision)
    }
    guard !busyKeyCodes.contains(keyCode) else {
      return .rejected(reason: .transactionInProgress)
    }
    busyKeyCodes.insert(keyCode)
    defer { busyKeyCodes.remove(keyCode) }
    let configurationBeforeOperation = configuration

    let pendingTarget = QuickBindingPendingTarget(
      url: url,
      kind: kind,
      preferredDisplayName: preferredDisplayName,
      shortcutChoice: shortcutChoice
    )
    guard session.expectedConfigurationRevision == configurationRevision else {
      // Refresh only the concurrency token. The first attempt is rejected so
      // the pending target cannot silently overwrite a host-side change.
      quickBindingSession = QuickBindingSession(
        id: session.id,
        keyCode: session.keyCode,
        expectedConfigurationRevision: configurationRevision,
        phase: .choosingTarget,
        pendingTarget: pendingTarget,
        chooserSnapshot: session.chooserSnapshot
      )
      errorMessage = "配置刚刚发生变化，请检查后再点一次重试。"
      statusText = errorMessage ?? "配置刚刚发生变化。"
      return .rejected(reason: .staleRevision)
    }
    guard session.phase != .systemPicker else {
      return .rejected(reason: .transactionInProgress)
    }
    guard !isCommitting, editingSession == nil else {
      resumeQuickBinding(
        sessionID: session.id,
        expectedConfigurationRevision: session.expectedConfigurationRevision,
        pendingTarget: pendingTarget
      )
      return .rejected(reason: .transactionInProgress)
    }

    quickBindingSession = QuickBindingSession(
      id: session.id,
      presentationID: session.presentationID,
      keyCode: session.keyCode,
      expectedConfigurationRevision: session.expectedConfigurationRevision,
      phase: .committing,
      pendingTarget: pendingTarget,
      chooserSnapshot: session.chooserSnapshot
    )
    errorMessage = nil

    let target: LaunchTarget
    do {
      if kind == .web {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
          throw LauncherError.unsupportedURLScheme
        }
        target = LaunchTarget(
          kind: .web,
          displayName: url.host ?? url.absoluteString,
          lastKnownURL: url
        )
      } else {
        guard url.isFileURL else {
          throw LauncherError.invalidConfiguration("文件系统目标必须是本地文件 URL")
        }
        let bookmark = bookmarkPolicy == .securityScopedWhenAvailable
          ? try bookmarkResolver.makeBookmark(for: url)
          : nil
        target = LaunchTarget(
          kind: kind,
          displayName: normalizedPreferredDisplayName(preferredDisplayName)
            ?? displayName(for: url, kind: kind),
          lastKnownURL: url,
          bookmarkData: bookmark
        )
      }
    } catch {
      report(error, prefix: "无法保存绑定")
      resumeQuickBinding(
        sessionID: session.id,
        expectedConfigurationRevision: session.expectedConfigurationRevision,
        pendingTarget: pendingTarget
      )
      throw error
    }

    var candidate: LauncherConfiguration
    do {
      candidate = try QuickBindingCandidateBuilder.makeCandidate(
        from: configuration,
        intent: QuickBindingIntent(
          slotKeyCode: keyCode,
          target: target,
          shortcutChoice: shortcutChoice
        )
      )
    } catch {
      report(error, prefix: "无法保存绑定")
      resumeQuickBinding(
        sessionID: session.id,
        expectedConfigurationRevision: session.expectedConfigurationRevision,
        pendingTarget: pendingTarget
      )
      return .validationFailed([validationIssue(for: error, configuration: configuration)])
    }

    // A first direct shortcut should work immediately. Once direct shortcuts
    // already exist, a persisted global pause is treated as explicit user
    // intent and remains untouched by adding or replacing one slot.
    let hadConfiguredDirectShortcut = configuration.bindings.values.contains {
      $0.directHotkey != nil
    }
    if !configuration.directModeEnabled,
      !hadConfiguredDirectShortcut,
      candidate.bindings[keyCode]?.directHotkey != nil
    {
      candidate.directModeEnabled = true
    }

    let result = await commit(LauncherCommitRequest(
      expectedConfigurationRevision: session.expectedConfigurationRevision,
      candidateConfiguration: candidate
    ))
    switch result {
    case .committed(let revision, let enabled):
      guard let savedRecord = candidate.bindings[keyCode] else { break }
      if savedRecord.target.kind == .web {
        beginWebsiteIconLoad(for: savedRecord, reason: .newBinding)
      }
      let publicBindingID = savedRecord.id.hostSafeProjection
      if savedRecord.directHotkey == nil {
        quickBindingSession = nil
        errorMessage = nil
        statusText = "已绑定 \(target.displayName)，可从面板直接打开。"
      } else if !candidate.directModeEnabled {
        quickBindingSession = nil
        errorMessage = nil
        statusText = "已绑定 \(target.displayName)；全局快捷键当前处于暂停状态。"
      } else if enabled.contains(publicBindingID), let shortcut = savedRecord.directHotkey {
        quickBindingSession = nil
        errorMessage = nil
        statusText = "已绑定 \(target.displayName)；现在可使用 \(hotkeyDisplayName(shortcut))。"
      } else if lifecycle.state != .started {
        quickBindingSession = nil
        errorMessage = nil
        statusText = "已保存 \(target.displayName)；模块启动后会启用快捷键。"
      } else {
        quickBindingSession = QuickBindingSession(
          id: session.id,
          keyCode: session.keyCode,
          expectedConfigurationRevision: revision,
          phase: .choosingTarget,
          pendingTarget: pendingTarget,
          chooserSnapshot: session.chooserSnapshot
        )
        let shortcut = savedRecord.directHotkey.map { hotkeyDisplayName($0) }
          ?? keyLabel(for: keyCode)
        errorMessage = "目标已更新，但快捷键 \(shortcut) 仍被占用；请选择其他修饰键重试。"
        statusText = errorMessage ?? "目标已更新，但快捷键仍有冲突。"
      }
      publishFeedback(
        kind: directConflictKeyCodes.contains(keyCode) ? .warning : .success,
        message: statusText,
        slotKeyCode: keyCode,
        undoToken: LauncherUndoToken(
          before: configurationBeforeOperation,
          expectedAfterRevision: revision,
          slotKeyCode: keyCode
        )
      )
      if uiPreferences.shouldShowOnboarding {
        Task { @MainActor [weak self] in
          _ = await self?.acknowledgeOnboarding()
        }
      }
    case .registrationFailed(_, let combination):
      statusText = "\(combination.displayName) 已被占用，请换一个修饰键后重试。"
      errorMessage = statusText
      resumeQuickBinding(
        sessionID: session.id,
        expectedConfigurationRevision: session.expectedConfigurationRevision,
        pendingTarget: pendingTarget
      )
    case .validationFailed:
      if errorMessage == nil { errorMessage = "这个目标或快捷键无法保存，请调整后重试。" }
      resumeQuickBinding(
        sessionID: session.id,
        expectedConfigurationRevision: session.expectedConfigurationRevision,
        pendingTarget: pendingTarget
      )
    case .persistenceFailed:
      if errorMessage == nil { errorMessage = "保存失败，原绑定没有改变。" }
      resumeQuickBinding(
        sessionID: session.id,
        expectedConfigurationRevision: session.expectedConfigurationRevision,
        pendingTarget: pendingTarget
      )
    case .rejected(.noChanges):
      quickBindingSession = nil
      errorMessage = nil
      statusText = "绑定没有变化。"
    case .rejected(let reason):
      if errorMessage == nil { errorMessage = quickBindingRejectionMessage(reason) }
      resumeQuickBinding(
        sessionID: session.id,
        expectedConfigurationRevision: reason == .staleRevision
          ? configurationRevision
          : session.expectedConfigurationRevision,
        pendingTarget: pendingTarget
      )
    }
    return result
  }

  /// Removes one binding as a complete transaction. The physical target is
  /// never deleted; only the launcher's local reference and registration are
  /// changed.
  public func quickRemoveBinding(for keyCode: UInt16) async -> LauncherCommitResult {
    guard editingSession == nil, !isCommitting else {
      return .rejected(reason: .transactionInProgress)
    }
    guard configuration.bindings[keyCode] != nil else {
      return .rejected(reason: .noChanges)
    }
    guard !busyKeyCodes.contains(keyCode) else {
      return .rejected(reason: .transactionInProgress)
    }
    busyKeyCodes.insert(keyCode)
    defer { busyKeyCodes.remove(keyCode) }
    let configurationBeforeOperation = configuration
    let expectedRevision = configurationRevision
    var candidate = configuration
    candidate.bindings.removeValue(forKey: keyCode)
    let result = await commit(LauncherCommitRequest(
      expectedConfigurationRevision: expectedRevision,
      candidateConfiguration: candidate
    ))
    if case .committed(let revision, _) = result {
      quickBindingSession = nil
      statusText = "已移除 \(keyLabel(for: keyCode)) 的绑定；原文件或应用未被删除。"
      publishFeedback(
        kind: .success,
        message: statusText,
        slotKeyCode: keyCode,
        undoToken: LauncherUndoToken(
          before: configurationBeforeOperation,
          expectedAfterRevision: revision,
          slotKeyCode: keyCode
        )
      )
    }
    return result
  }

  /// Closes the slot editor. Normal one-slot edits are discarded immediately;
  /// an advanced batch-edit draft remains available on the main panel.
  public func closeBindingEditor() {
    guard !isCommitting else {
      statusText = "正在保存；编辑器会保留到本次操作完成。"
      return
    }
    bindingRequestKeyCode = nil
    guard singleBindingTransaction != nil else { return }
    let changed = editingSession?.hasChanges == true
    editingSession = nil
    singleBindingTransaction = nil
    errorMessage = nil
    if changed { statusText = "本次单个绑定修改未保存。" }
  }

  public func chooseTarget(kind: LaunchTargetKind, for keyCode: UInt16) {
    guard allowDraftMutation() else { return }
    guard kind != .web, KeySlotCatalog.allowedKeyCodes.contains(keyCode) else { return }
    guard allowsSingleSlotMutation(keyCode) else { return }
    if let requiredKind = requiredRepairTargetKind(for: keyCode), kind != requiredKind {
      statusText = "请重新选择同类型的\(requiredKind.displayName)，以保留当前绑定身份和快捷键。"
      return
    }
    if editingSession == nil { beginSingleBindingEditing(for: keyCode) }

    let keyLabel = keyLabel(for: keyCode)
    guard let url = targetPicker.chooseTarget(kind: kind, panelKeyLabel: keyLabel) else {
      statusText = "已取消选择，原目标未改变。"
      return
    }

    do {
      let bookmark = bookmarkPolicy == .securityScopedWhenAvailable
        ? try bookmarkResolver.makeBookmark(for: url)
        : nil
      setDraftTarget(
        LaunchTarget(
          kind: kind,
          displayName: displayName(for: url, kind: kind),
          lastKnownURL: url,
          bookmarkData: bookmark
        ),
        at: keyCode
      )
      statusText = "\(keyLabel) 草稿已更新：\(displayName(for: url, kind: kind))"
    } catch {
      report(error)
    }
  }

  public func bindWebURL(_ rawValue: String, to keyCode: UInt16) {
    guard allowDraftMutation() else { return }
    guard allowsSingleSlotMutation(keyCode) else { return }
    if let requiredKind = requiredRepairTargetKind(for: keyCode), requiredKind != .web {
      statusText = "当前正在修复\(requiredKind.displayName)目标，请重新选择同类型目标。"
      return
    }
    do {
      let url = try WebURLValidator.normalize(rawValue)
      setDraftTarget(
        LaunchTarget(
          kind: .web,
          displayName: url.host ?? url.absoluteString,
          lastKnownURL: url
        ),
        at: keyCode
      )
      statusText = "\(KeySlotCatalog.label(for: keyCode)) 的网页已加入草稿。"
    } catch {
      report(error)
    }
  }

  public func clearBinding(for keyCode: UInt16) {
    guard allowDraftMutation() else { return }
    guard allowsSingleSlotMutation(keyCode) else { return }
    if editingSession == nil { beginSingleBindingEditing(for: keyCode) }
    updateSession { $0.removeBinding(at: keyCode) }
    if singleBindingTransaction == nil { bindingRequestKeyCode = nil }
    statusText = "\(KeySlotCatalog.label(for: keyCode)) 的绑定已从草稿移除。"
  }

  public func setDraftDirectHotkey(_ hotkey: HotkeyDefinition?, for keyCode: UInt16) {
    guard allowDraftMutation() else { return }
    guard allowsSingleSlotMutation(keyCode) else { return }
    do {
      try hotkey?.validate()
      if editingSession == nil { beginSingleBindingEditing(for: keyCode) }
      guard editingSession?.draft.bindings[keyCode] != nil else {
        throw LauncherError.noBinding
      }
      updateSession {
        $0.setDirectHotkey(hotkey, at: keyCode)
        if hotkey != nil {
          // A configured direct shortcut must never remain silently paused because
          // the separate master switch was forgotten. Both changes belong to the
          // same draft and are committed (or rolled back) together.
          $0.draft.directModeEnabled = true
        } else if singleBindingTransaction != nil {
          // Clearing a candidate in a one-slot transaction must not silently
          // change the persisted pause/resume choice for every other binding.
          $0.draft.directModeEnabled = configuration.directModeEnabled
        }
      }
      errorMessage = nil
      statusText = hotkey.map {
        "全局快捷键 \($0.displayName) 已加入草稿，保存后自动启用。"
      } ?? "这个绑定的全局快捷键已从草稿清除。"
    } catch {
      report(error)
    }
  }

  public func setDraftPanelHotkey(_ hotkey: HotkeyDefinition) {
    guard allowDraftMutation() else { return }
    guard allowsGlobalDraftMutation() else { return }
    do {
      try hotkey.validate()
      if editingSession == nil { beginEditing() }
      updateSession { $0.draft.panelHotkey = hotkey }
      statusText = "面板快捷键已加入草稿：\(hotkey.displayName)"
    } catch {
      report(error)
    }
  }

  public func setDraftDirectModeEnabled(_ enabled: Bool) {
    guard allowDraftMutation() else { return }
    guard allowsGlobalDraftMutation() else { return }
    if editingSession == nil { beginEditing() }
    updateSession { $0.draft.directModeEnabled = enabled }
    statusText = enabled ? "保存后将恢复全部全局快捷键。" : "保存后将暂停全部全局快捷键。"
  }

  public func moveBinding(from source: UInt16, to destination: UInt16) {
    guard allowDraftMutation() else { return }
    guard allowsGlobalDraftMutation() else { return }
    guard isEditing else { return }
    updateSession { $0.moveOrSwap(from: source, to: destination) }
    statusText = "已调整槽位；点击保存后生效。"
  }

  public func resetDraftToDefaults() {
    guard allowDraftMutation() else { return }
    guard allowsGlobalDraftMutation() else { return }
    if editingSession == nil { beginEditing() }
    guard var session = editingSession else { return }
    session.draft = LauncherConfiguration()
    session.dirtyKeys = Set(KeySlotCatalog.allowedKeyCodes)
    editingSession = session
    statusText = "已恢复默认草稿；点击保存后生效。"
  }

  public func execute(bindingID: BindingID, source: TriggerSource) async {
    // Compatibility facade: schema-v3 historically accepted arbitrary raw
    // identifiers. Preserve exact lookup here even when one old raw value
    // happens to equal another record's host-facing privacy alias.
    guard lifecycle.state == .started, lifecycleOperation == .idle else {
      statusText = "快捷启动模块当前不可用，请先启动后再试。"
      return
    }
    guard let keyCode = configuration.keyCode(for: bindingID),
      let record = configuration.bindings[keyCode]
    else {
      report(LauncherError.noBinding)
      return
    }
    _ = await performExecution(record: record, keyCode: keyCode, source: source)
  }

  @discardableResult
  public func executeWithResult(
    bindingID: BindingID,
    source: TriggerSource
  ) async -> ExecutionResult {
    let publicBindingID = configuration.binding(hostFacingID: bindingID)?.id.hostSafeProjection
      ?? bindingID.hostSafeProjection
    guard lifecycle.state == .started, lifecycleOperation == .idle else {
      statusText = "快捷启动模块当前不可用，请先启动后再试。"
      return .failed(publicBindingID, code: .moduleUnavailable)
    }
    guard let keyCode = configuration.keyCode(forHostFacingBindingID: bindingID) else {
      report(LauncherError.noBinding)
      return .failed(publicBindingID, code: .noBinding)
    }
    guard let record = configuration.bindings[keyCode] else {
      report(LauncherError.noBinding)
      return .failed(publicBindingID, code: .noBinding)
    }
    return await performExecution(record: record, keyCode: keyCode, source: source)
  }

  public func executeBinding(keyCode: UInt16, source: TriggerSource) async {
    guard lifecycle.state == .started, lifecycleOperation == .idle else {
      statusText = "快捷启动模块当前不可用，请先启动后再试。"
      return
    }
    // The release gate prevents the invocation chord from being interpreted as
    // a second keyboard action. Pointer clicks are independent input and must
    // be usable immediately after the panel becomes visible.
    if source == .panelKeyboard, !releaseGate.isArmed {
      statusText = "请先释放唤出组合键。"
      return
    }
    guard let record = configuration.bindings[keyCode] else {
      statusText = LauncherError.noBinding.localizedDescription
      if source != .directHotkey { requestQuickBinding(for: keyCode) }
      return
    }

    _ = await performExecution(record: record, keyCode: keyCode, source: source)
  }

  private func performExecution(
    record: BindingRecord,
    keyCode: UInt16,
    source: TriggerSource,
    executionConfigurationRevision frozenRevision: UInt64? = nil
  ) async -> ExecutionResult {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let executionConfigurationRevision = frozenRevision ?? configurationRevision
    var targetWasResolved = false

    do {
      let target = record.target
      let resolvedURL: URL
      var accessedSecurityScope = false
      var staleBookmarkURL: URL?

      if target.kind == .web {
        resolvedURL = target.lastKnownURL
      } else if let bookmarkData = target.bookmarkData {
        let resolved = try bookmarkResolver.resolve(bookmarkData)
        resolvedURL = resolved.url
        accessedSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        if resolved.isStale {
          staleBookmarkURL = resolvedURL
        }
      } else {
        resolvedURL = target.lastKnownURL
      }
      targetWasResolved = true

      defer {
        if accessedSecurityScope { resolvedURL.stopAccessingSecurityScopedResource() }
      }
      try await opener.open(target: record.target, resolvedURL: resolvedURL)
      let shouldPublishResult = isCurrentExecutionContext(
        record: record,
        keyCode: keyCode,
        revision: executionConfigurationRevision
      )
      logger.notice("target_open_accepted kind=\(record.target.kind.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public)")
      if shouldPublishResult {
        invalidKeyCodes.remove(keyCode)
        if repairPrompt?.bindingID == record.id.hostSafeProjection {
          repairPrompt = nil
          feedbackPresenter.dismiss(bindingID: record.id.hostSafeProjection)
        }
        statusText = "已打开：\(privacySafeDisplayName(for: record))"
        if source != .directHotkey { dismissPanel() }
      } else {
        diagnosticsSink.record(code: "stale_execution_result_discarded", metadata: [:])
      }

      if shouldPublishResult, let staleBookmarkURL {
        let refreshed = await refreshStaleBookmark(
          bindingID: record.id,
          originalTarget: target,
          resolvedURL: staleBookmarkURL
        )
        if !refreshed,
          isCurrentExecutionContext(
            record: record,
            keyCode: keyCode,
            revision: executionConfigurationRevision
          )
        {
          statusText = "已打开：\(privacySafeDisplayName(for: record))；访问引用刷新失败，但不影响本次打开。"
        }
      }
      eventSink.receive(LauncherEvent(
        name: .bindingExecuted,
        bindingID: record.id,
        targetKind: record.target.kind,
        triggerSource: source,
        resultCode: "accepted",
        durationMilliseconds: elapsedMilliseconds(since: startedAt),
        configurationRevision: executionConfigurationRevision
      ))
      return .accepted(record.id.hostSafeProjection)
    } catch {
      let failureCode: ExecutionFailureCode = targetWasResolved
        ? .openRejected : .targetResolutionFailed
      let shouldPublishResult = isCurrentExecutionContext(
        record: record,
        keyCode: keyCode,
        revision: executionConfigurationRevision
      )
      diagnosticsSink.record(code: "target_open_failed", metadata: ["kind": record.target.kind.rawValue])
      eventSink.receive(LauncherEvent(
        name: .bindingExecutionFailed,
        bindingID: record.id,
        targetKind: record.target.kind,
        triggerSource: source,
        resultCode: failureCode.rawValue,
        durationMilliseconds: elapsedMilliseconds(since: startedAt),
        configurationRevision: executionConfigurationRevision
      ))
      let safeDisplayName = privacySafeDisplayName(for: record)
      let safeMessage = "无法打开 \(safeDisplayName)。旧绑定仍保留，可重新选择目标后再试。"
      logger.error("target_open_failed detail=\(error.localizedDescription, privacy: .private)")
      if shouldPublishResult {
        if record.target.kind != .web { invalidKeyCodes.insert(keyCode) }
        if source == .directHotkey {
          let prompt = LauncherRepairPrompt(
            bindingID: record.id,
            displayName: safeDisplayName,
            targetKind: record.target.kind,
            errorCode: failureCode
          )
          repairPrompt = prompt
          feedbackPresenter.present(prompt)
          if presentsRepairUIOnDirectFailure { presentPanel() }
          statusText = safeMessage
          errorMessage = nil
        } else {
          statusText = safeMessage
          errorMessage = safeMessage
        }
      } else {
        diagnosticsSink.record(code: "stale_execution_result_discarded", metadata: [:])
      }
      if record.target.kind != .web {
        return .targetUnavailable(record.id.hostSafeProjection)
      }
      return .failed(record.id.hostSafeProjection, code: failureCode)
    }
  }

  private func isCurrentExecutionContext(
    record: BindingRecord,
    keyCode: UInt16,
    revision: UInt64
  ) -> Bool {
    lifecycle.state == .started
      && lifecycleOperation == .idle
      && !isCommitting
      && configurationRevision == revision
      && configuration.bindings[keyCode] == record
  }

  public func openRepairPrompt() {
    guard let repairPrompt,
      let keyCode = configuration.keyCode(forHostFacingBindingID: repairPrompt.bindingID)
    else { return }
    self.repairPrompt = nil
    feedbackPresenter.dismiss(bindingID: repairPrompt.bindingID)
    requestQuickBinding(for: keyCode)
  }

  public func dismissRepairPrompt() {
    if let bindingID = repairPrompt?.bindingID {
      feedbackPresenter.dismiss(bindingID: bindingID)
    }
    repairPrompt = nil
  }

  public func retryDirectHotkey(bindingID: BindingID) async -> HotkeyRetryResult {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let resolvedRecord = configuration.binding(hostFacingID: bindingID)
    let publicBindingID = resolvedRecord?.id.hostSafeProjection ?? bindingID.hostSafeProjection
    func finish(_ result: HotkeyRetryResult, code: String) -> HotkeyRetryResult {
      eventSink.receive(LauncherEvent(
        name: .directHotkeyRetry,
        bindingID: resolvedRecord?.id,
        targetKind: resolvedRecord?.target.kind,
        resultCode: code,
        durationMilliseconds: elapsedMilliseconds(since: startedAt),
        configurationRevision: configurationRevision
      ))
      return result
    }
    guard lifecycle.state == .started,
      lifecycleOperation == .idle,
      !isCommitting,
      hotkeyRecorderSessionIDs.isEmpty,
      configuration.directModeEnabled,
      let keyCode = configuration.keyCode(forHostFacingBindingID: bindingID),
      let record = configuration.bindings[keyCode],
      let hotkey = record.directHotkey
    else {
      if resolvedRecord?.directHotkey == nil {
        return finish(.notConfigured(publicBindingID), code: "not-configured")
      }
      return finish(.moduleUnavailable, code: "module-unavailable")
    }

    let id = HotkeyID.direct(bindingID: record.id)
    if registeredHotkeyIDs.contains(id) {
      directConflictKeyCodes.remove(keyCode)
      return finish(.enabled(publicBindingID), code: "enabled")
    }

    isCommitting = true
    defer { finishConfigurationTransaction() }
    do {
      try await registrar.register(hotkey, id: id)
      registeredHotkeyIDs.insert(id)
      directConflictKeyCodes.remove(keyCode)
      errorMessage = nil
      let safeTargetName = configuration.bindings[keyCode]
        .map(privacySafeDisplayName(for:)) ?? "该目标"
      statusText = "\(safeTargetName) 的 \(hotkeyDisplayName(hotkey)) 已启用。"
      return finish(.enabled(publicBindingID), code: "enabled")
    } catch {
      directConflictKeyCodes.insert(keyCode)
      diagnosticsSink.record(code: "direct_hotkey_retry_conflict", metadata: ["slot": String(keyCode)])
      report(
        LauncherError.hotkeyUnavailable(
          target: configuration.bindings[keyCode]
            .map(privacySafeDisplayName(for:)) ?? "该绑定",
          combination: hotkeyDisplayName(hotkey)
        )
      )
      return finish(.stillConflicted(publicBindingID), code: "conflicted")
    }
  }

  public func exportConfiguration() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.shortcutLauncherConfiguration]
    panel.nameFieldStringValue = "快捷启动配置.shortcutlauncherconfig"
    panel.message = "导出文件可能包含目标路径和访问引用，请勿公开分享。"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let candidate = configuration
    statusText = "正在导出配置…"
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let data = try await repository.exportData(for: candidate)
        try await Task.detached(priority: .userInitiated) {
          try data.write(to: url, options: .atomic)
        }.value
        statusText = "配置已导出。"
      } catch {
        report(error, prefix: "无法导出配置")
      }
    }
  }

  public func importConfiguration() async {
    guard allowDraftMutation() else { return }
    guard allowsGlobalDraftMutation() else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.shortcutLauncherConfiguration, .json]
    panel.message = "选择快捷启动配置文件"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let data = try await Task.detached(priority: .userInitiated) {
        try Data(contentsOf: url)
      }.value
      let prepared = try await repository.prepareImport(data)
      let confirmation = NSAlert()
      confirmation.messageText = "确认导入配置？"
      confirmation.informativeText = "\(prepared.preview.summary)\n\n导入会先备份当前配置；失效文件可在之后重新定位。"
      confirmation.addButton(withTitle: "导入")
      confirmation.addButton(withTitle: "取消")
      guard confirmation.runModal() == .alertFirstButtonReturn else { return }

      guard !isCommitting else {
        statusText = "已有配置正在保存，请完成后再导入。"
        return
      }
      guard lifecycleOperation == .idle else {
        statusText = "快捷键生命周期正在切换，请稍候再导入。"
        return
      }
      isCommitting = true
      defer { finishConfigurationTransaction() }
      try await applyConfiguration(prepared.configuration)
      editingSession = nil
      statusText = "配置已导入并生效。"
      eventSink.receive(LauncherEvent(
        name: .importCompleted,
        resultCode: "success",
        configurationRevision: configurationRevision
      ))
    } catch {
      report(error, prefix: "无法导入配置")
    }
  }

  func handlePanelEvent(
    _ event: NSEvent,
    ownership: PanelInputOwnership = .panel
  ) -> Bool {
    let kind: PanelInputEvent.Kind
    switch event.type {
    case .keyDown: kind = .keyDown
    case .keyUp: kind = .keyUp
    case .flagsChanged: kind = .flagsChanged
    default: return false
    }

    let wasArmed = releaseGate.isArmed
    let decision = panelInputPolicy.evaluate(
      PanelInputEvent(
        kind: kind,
        keyCode: event.keyCode,
        modifiers: LocalHotkeyRecorderNSView.modifierSet(from: event.modifierFlags),
        isRepeat: event.isARepeat
      ),
      ownership: ownership,
      releaseGate: &releaseGate
    )
    isArmed = releaseGate.isArmed
    if !wasArmed, isArmed { statusText = armedStatusText }

    switch decision {
    case .passThrough:
      return false
    case .consume:
      return true
    case .dismissPanel:
      if isEditing { requestCancelEditing() } else { dismissPanel() }
      return true
    case .activateSlot(let keyCode):
      if isEditing {
        requestBinding(for: keyCode)
      } else if configuration.bindings[keyCode] == nil {
        requestQuickBinding(for: keyCode)
      } else {
        Task { @MainActor [weak self] in
          await self?.executeBinding(keyCode: keyCode, source: .panelKeyboard)
        }
      }
      return true
    }
  }

  private func synchronizeReleaseGateWithSystemKeyboardState() {
    guard case .waitingForRelease(let invocationKeyCode) = releaseGate.state else { return }
    let invocationKeyIsDown = CGEventSource.keyState(
      .combinedSessionState,
      key: CGKeyCode(invocationKeyCode)
    )
    let currentModifiers = LocalHotkeyRecorderNSView.modifierSet(
      from: NSEvent.modifierFlags
    )
    if releaseGate.synchronize(
      invocationKeyIsDown: invocationKeyIsDown,
      currentModifiers: currentModifiers
    ) {
      isArmed = true
      statusText = armedStatusText
    }
  }

  // MARK: - Compatibility wrappers

  public func chooseTarget(kind: LaunchTargetKind) { chooseTarget(kind: kind, for: PhysicalKeyCode.q) }
  public func bindWebURL(_ rawValue: String) { bindWebURL(rawValue, to: PhysicalKeyCode.q) }
  public func clearBinding() { clearBinding(for: PhysicalKeyCode.q) }
  public func executeQBinding(source: TriggerSource) async {
    await executeBinding(keyCode: PhysicalKeyCode.q, source: source)
  }
  public func updatePanelHotkey(_ hotkey: HotkeyDefinition) async {
    _ = await applyLauncherSettings(
      panelHotkey: hotkey,
      directModeEnabled: configuration.directModeEnabled
    )
  }
  public func setDirectModeEnabled(_ enabled: Bool) async {
    guard editingSession == nil else {
      statusText = "请先保存或取消当前编辑，再暂停或恢复全部全局快捷键。"
      return
    }
    _ = await applyLauncherSettings(
      panelHotkey: configuration.panelHotkey,
      directModeEnabled: enabled
    )
  }

  /// Applies launcher-wide settings without allocating a batch-edit draft.
  /// The complete candidate still uses the existing revision-aware staged
  /// registration and persistence transaction.
  public func applyLauncherSettings(
    panelHotkey: HotkeyDefinition,
    directModeEnabled: Bool,
    expectedConfigurationRevision: UInt64? = nil
  ) async -> LauncherCommitResult {
    guard editingSession == nil, !isCommitting else {
      statusText = "请先完成当前编辑或保存操作。"
      return .rejected(reason: .transactionInProgress)
    }
    do {
      try panelHotkey.validate()
    } catch {
      report(error, prefix: "无法保存设置")
      return .validationFailed([validationIssue(for: error, configuration: configuration)])
    }
    let previousPanelHotkey = configuration.panelHotkey
    let previousDirectModeEnabled = configuration.directModeEnabled
    var candidate = configuration
    candidate.panelHotkey = panelHotkey
    candidate.directModeEnabled = directModeEnabled
    let result = await commit(LauncherCommitRequest(
      expectedConfigurationRevision: expectedConfigurationRevision ?? configurationRevision,
      candidateConfiguration: candidate
    ))
    switch result {
    case .committed:
      errorMessage = nil
      if previousPanelHotkey != panelHotkey,
        previousDirectModeEnabled == directModeEnabled
      {
        statusText = "打开面板快捷键已修改为 \(hotkeyDisplayName(panelHotkey))。"
      } else {
        statusText = directModeEnabled
          ? "设置已保存；可用的全局快捷键已启用。"
          : "设置已保存；全局快捷键已暂停，面板内打开仍可用。"
      }
      publishFeedback(kind: .success, message: statusText)
    case .rejected(.noChanges):
      statusText = "设置没有变化。"
    default:
      break
    }
    return result
  }

  @discardableResult
  public func setAppearance(_ appearance: LauncherAppearance) async -> Bool {
    var candidate = uiPreferences
    candidate.appearance = appearance
    return await persistUIPreferences(
      candidate,
      successMessage: "外观设置已更新。"
    )
  }

  @discardableResult
  public func setOnlineWebsiteIconsEnabled(_ enabled: Bool) async -> Bool {
    var candidate = uiPreferences
    candidate.onlineWebsiteIconsEnabled = enabled
    let didSave = await persistUIPreferences(
      candidate,
      successMessage: enabled
        ? "已开启在线获取网站图标。"
        : "已关闭在线获取；绑定和打开网站不受影响。"
    )
    if didSave, let iconManager = websiteIconProvider as? any WebsiteIconManaging {
      await iconManager.setOnlineFetchingEnabled(enabled)
    }
    return didSave
  }

  public var canManageWebsiteIcons: Bool {
    websiteIconProvider is any WebsiteIconManaging
  }

  /// Refreshes one website icon without involving the binding transaction.
  /// A failure stays a visual fallback and never changes target availability.
  public func refreshWebsiteIcon(for keyCode: UInt16) async {
    guard let record = configuration.bindings[keyCode],
      let request = websiteIconRequest(for: keyCode, reason: .userRefresh)
    else { return }
    let displayName = privacySafeDisplayName(for: record)
    _ = await websiteIconProvider.refresh(request)
    publishFeedback(
      kind: .information,
      message: "已刷新 \(displayName) 的网站图标。",
      slotKeyCode: keyCode
    )
  }

  /// Explicit one-shot backfill for existing websites. Passive panel display
  /// remains cache-only and therefore never silently contacts old origins.
  public func backfillWebsiteIcons() async {
    guard lifecycle.state == .started, lifecycleOperation == .idle else { return }
    let operationLifecycleGeneration = lifecycleGeneration
    let requests = configuration.bindings.values.compactMap { record -> WebsiteIconRequest? in
      guard record.target.kind == .web else { return nil }
      return WebsiteIconRequest(
        bindingID: record.id,
        websiteURL: record.target.lastKnownURL,
        reason: .explicitBackfill
      )
    }
    guard !requests.isEmpty else {
      publishFeedback(kind: .information, message: "当前没有需要补齐图标的网站。")
      return
    }
    let provider = websiteIconProvider
    await withTaskGroup(of: Void.self) { group in
      for request in requests {
        group.addTask {
          _ = await provider.icon(for: request)
        }
      }
    }
    guard lifecycle.state == .started,
      lifecycleOperation == .idle,
      lifecycleGeneration == operationLifecycleGeneration
    else { return }
    publishFeedback(kind: .information, message: "已检查 \(requests.count) 个网站的图标。")
  }

  public func clearAutomaticWebsiteIconCache() async {
    guard let iconManager = websiteIconProvider as? any WebsiteIconManaging else {
      publishFeedback(kind: .warning, message: "当前宿主未提供可清理的网站图标缓存。")
      return
    }
    await iconManager.clearAutomaticCache()
    publishFeedback(kind: .information, message: "已清理自动网站图标缓存；自定义图标仍保留。")
  }

  /// Lets the user choose a local image, then copies a validated normalized
  /// artifact into the icon service's managed directory.
  public func chooseCustomWebsiteIcon(for keyCode: UInt16) async {
    guard let request = websiteIconRequest(for: keyCode, reason: .userRefresh) else { return }
    guard let iconManager = websiteIconProvider as? any WebsiteIconManaging else {
      publishFeedback(kind: .warning, message: "当前宿主不支持自定义网站图标。")
      return
    }
    guard let imageURL = await websiteIconImagePicker.chooseImage(
      presentationWindow: panelPresenter?.targetPickerPresentationWindow
    ) else { return }

    do {
      let maximumBytes = WebsiteIconFetchPolicy.production.maximumImageBytes
      let imageData = try await Task.detached(priority: .userInitiated) {
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
          let fileSize = values.fileSize,
          fileSize > 0,
          fileSize <= maximumBytes
        else {
          throw WebsiteIconImageError.decodeFailed
        }
        return try Data(contentsOf: imageURL, options: [.mappedIfSafe])
      }.value
      if let mutation = try await iconManager.storeCustomIcon(
        imageData: imageData,
        for: request
      ) {
        // A custom-asset mutation is a newer user action outside the Core
        // configuration revision. Retire any older configuration undo token so
        // it cannot restore a target whose previous icon was just finalized.
        dismissFeedback()
        await iconManager.finalizeCustomIconMutation(mutation)
      }
      publishFeedback(
        kind: .success,
        message: "自定义网站图标已保存。",
        slotKeyCode: keyCode
      )
    } catch {
      diagnosticsSink.record(code: "custom_website_icon_rejected", metadata: [:])
      publishFeedback(
        kind: .warning,
        message: "无法使用这张图片；请选择不超过 1 MB 的 PNG、JPEG、GIF 或 ICO。",
        slotKeyCode: keyCode
      )
    }
  }

  public func restoreAutomaticWebsiteIcon(for keyCode: UInt16) async {
    guard let request = websiteIconRequest(for: keyCode, reason: .userRefresh) else { return }
    guard let iconManager = websiteIconProvider as? any WebsiteIconManaging else {
      publishFeedback(kind: .warning, message: "当前宿主不支持恢复网站图标。")
      return
    }
    do {
      if let mutation = try await iconManager.removeCustomIcon(for: request) {
        dismissFeedback()
        await iconManager.finalizeCustomIconMutation(mutation)
      }
      _ = await websiteIconProvider.refresh(request)
      publishFeedback(
        kind: .information,
        message: "已恢复自动网站图标。",
        slotKeyCode: keyCode
      )
    } catch {
      diagnosticsSink.record(code: "custom_website_icon_restore_failed", metadata: [:])
      publishFeedback(
        kind: .warning,
        message: "暂时无法恢复图标；当前绑定和原图标保持不变。",
        slotKeyCode: keyCode
      )
    }
  }

  @discardableResult
  public func acknowledgeOnboarding(version: Int = 1) async -> Bool {
    guard uiPreferences.onboardingVersion < version else { return true }
    var candidate = uiPreferences
    candidate.onboardingVersion = version
    return await persistUIPreferences(candidate, successMessage: nil)
  }

  @discardableResult
  public func showOnboardingAgain() async -> Bool {
    var candidate = uiPreferences
    candidate.onboardingVersion = 0
    return await persistUIPreferences(
      candidate,
      successMessage: "使用提示已重新显示。"
    )
  }

  private func persistUIPreferences(
    _ candidate: LauncherUIPreferences,
    successMessage: String?
  ) async -> Bool {
    guard !isSavingUIPreferences else {
      statusText = "正在保存界面设置，请稍候。"
      return false
    }
    guard candidate != uiPreferences else { return true }
    do {
      _ = try candidate.validated()
      isSavingUIPreferences = true
      defer { isSavingUIPreferences = false }
      try await uiPreferencesStore.save(candidate)
      uiPreferences = candidate
      uiPreferencesRevision &+= 1
      if let successMessage {
        statusText = successMessage
        publishFeedback(kind: .success, message: successMessage)
      }
      return true
    } catch {
      statusText = "界面设置未能保存；当前选择保持不变。"
      publishFeedback(kind: .warning, message: statusText)
      diagnosticsSink.record(code: "ui_preferences_save_failed", metadata: [:])
      return false
    }
  }
  public func updateDirectModifiers(_ modifiers: ModifierSet) async {
    guard allowDraftMutation() else { return }
    guard allowsGlobalDraftMutation() else { return }
    if editingSession == nil { beginEditing() }
    guard var session = editingSession else { return }
    for keyCode in session.draft.bindings.keys {
      session.setDirectHotkey(
        HotkeyDefinition(keyCode: keyCode, modifiers: modifiers),
        at: keyCode
      )
    }
    editingSession = session
    await commitEditing()
  }

  private var armedStatusText: String {
    isArmed
      ? "面板已就绪。点击任意键位可设置；按已绑定的面板键可打开目标。"
      : "面板已打开；可直接点击任意键位设置。若使用键盘，请先释放唤出组合键。"
  }

  private var publicLifecycleState: LauncherLifecycleState {
    switch lifecycleOperation {
    case .starting:
      return .starting
    case .stopping:
      return .stopping
    case .idle:
      return lifecycle.state == .started ? .running : .stopped
    }
  }

  private func resolvedPanelPresenter() -> any LauncherPanelPresenting {
    if let panelPresenter { return panelPresenter }
    let presenter = panelPresenterFactory?(self) ?? LauncherPanelController(module: self)
    panelPresenter = presenter
    return presenter
  }

  private func setDraftTarget(_ target: LaunchTarget, at keyCode: UInt16) {
    guard allowDraftMutation() else { return }
    guard allowsSingleSlotMutation(keyCode) else { return }
    if editingSession == nil { beginSingleBindingEditing(for: keyCode) }
    updateSession { $0.setTarget(target, at: keyCode) }
    errorMessage = nil
  }

  private func updateSession(_ update: (inout BindingEditSession) -> Void) {
    guard allowDraftMutation() else { return }
    guard var session = editingSession else { return }
    update(&session)
    editingSession = session
    if var transaction = singleBindingTransaction {
      transaction.draft = session.draft.bindings[transaction.slotKeyCode]
      transaction.shouldEnableAllDirectHotkeysOnCommit =
        transaction.draft?.directHotkey != nil
        && session.draft.directModeEnabled
        && !configuration.directModeEnabled
      singleBindingTransaction = transaction
    }
  }

  private func beginSingleBindingEditing(for keyCode: UInt16) {
    guard editingSession == nil,
      KeySlotCatalog.allowedKeyCodes.contains(keyCode)
    else { return }
    editingSession = BindingEditSession(configuration: configuration)
    singleBindingTransaction = SingleBindingEditTransaction(
      slotKeyCode: keyCode,
      original: configuration.bindings[keyCode]
    )
    errorMessage = nil
    statusText = "编辑面板按键 \(KeySlotCatalog.label(for: keyCode))。选择目标，并可直接录制全局快捷键。"
  }

  private func allowDraftMutation() -> Bool {
    guard !isCommitting else {
      statusText = "正在保存并注册快捷键，请稍候。"
      return false
    }
    guard lifecycleOperation == .idle else {
      statusText = "快捷键生命周期正在切换，请稍候。"
      return false
    }
    return true
  }

  private func allowsSingleSlotMutation(_ keyCode: UInt16) -> Bool {
    guard let transaction = singleBindingTransaction else { return true }
    guard transaction.slotKeyCode == keyCode else {
      statusText = "请先保存或取消当前单个绑定，再编辑其他面板按键。"
      return false
    }
    return true
  }

  private func allowsGlobalDraftMutation() -> Bool {
    guard singleBindingTransaction == nil else {
      statusText = "请先保存或取消当前单个绑定，再修改全局设置。"
      return false
    }
    return true
  }

  private func waitForConfigurationTransaction() async {
    guard isCommitting else { return }
    await withCheckedContinuation { continuation in
      configurationTransactionWaiters.append(continuation)
    }
  }

  private func finishConfigurationTransaction() {
    isCommitting = false
    let waiters = configurationTransactionWaiters
    configurationTransactionWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func acquireLifecycleOperation(_ operation: LifecycleOperation) async {
    guard lifecycleOperation != .idle else {
      lifecycleOperation = operation
      return
    }
    await withCheckedContinuation { continuation in
      lifecycleOperationWaiters.append(LifecycleOperationWaiter(
        operation: operation,
        continuation: continuation
      ))
    }
  }

  private func finishLifecycleOperation() {
    guard !lifecycleOperationWaiters.isEmpty else {
      lifecycleOperation = .idle
      return
    }
    let next = lifecycleOperationWaiters.removeFirst()
    lifecycleOperation = next.operation
    next.continuation.resume()
  }

  private func advanceLifecycleGeneration() {
    lifecycleGeneration &+= 1
    if lifecycleGeneration == 0 { lifecycleGeneration = 1 }
  }

  private func registerAllDirectHotkeys() async {
    directConflictKeyCodes.removeAll()
    for (keyCode, record) in configuration.bindings.sorted(by: { $0.key < $1.key }) {
      guard let hotkey = record.directHotkey else { continue }
      do {
        try await registrar.register(hotkey, id: .direct(bindingID: record.id))
        registeredHotkeyIDs.insert(.direct(bindingID: record.id))
      } catch {
        directConflictKeyCodes.insert(keyCode)
        diagnosticsSink.record(code: "direct_hotkey_conflict", metadata: ["slot": String(keyCode)])
      }
    }
  }

  private func restoreHotkeysAfterRecorderIfNeeded() async {
    guard let suspendedHotkeys = recorderSuspendedHotkeys else { return }
    let preservedConflicts = recorderSuspendedConflictKeyCodes

    if isCommitting { await waitForConfigurationTransaction() }
    guard lifecycle.state == .started, lifecycleOperation == .idle else {
      recorderSuspendedHotkeys = nil
      recorderSuspendedConflictKeyCodes.removeAll()
      return
    }

    // Recorder restoration owns the same serialization boundary as a config
    // transaction. A concurrent stop must wait and perform the final teardown
    // after this rebuild, never race it and leave post-stop registrations.
    isCommitting = true
    defer { finishConfigurationTransaction() }
    let failures = await rebuildHotkeyRegistrations(
      suspendedHotkeys,
      configuration: configuration,
      preservingConflicts: preservedConflicts
    )
    recorderSuspendedHotkeys = nil
    recorderSuspendedConflictKeyCodes.removeAll()
    updateRegistrationRecoveryIssues(for: failures)
    if failures.contains(.panel) {
      statusText = "面板快捷键未能恢复，请暂停并重新启动快捷启动模块。"
      errorMessage = statusText
    } else if !failures.isEmpty {
      statusText = "部分全局快捷键暂时冲突；其他绑定仍可继续使用。"
    }
  }

  private func desiredHotkeys(for configuration: LauncherConfiguration) -> [HotkeyID: HotkeyDefinition] {
    var result: [HotkeyID: HotkeyDefinition] = [.panel: configuration.panelHotkey]
    if configuration.directModeEnabled {
      for record in configuration.bindings.values {
        if let hotkey = record.directHotkey {
          result[.direct(bindingID: record.id)] = hotkey
        }
      }
    }
    return result
  }

  private func applyConfiguration(_ candidate: LauncherConfiguration) async throws {
    try ConfigurationValidator.validate(candidate)
    let oldConfiguration = configuration
    guard lifecycle.state == .started else {
      try await persistCandidate(candidate, restoring: oldConfiguration)
      invalidKeyCodes = remappedInvalidKeyCodes(from: oldConfiguration, to: candidate)
      configuration = candidate
      configurationRevision &+= 1
      scheduleObsoleteWebsiteIconCleanups(from: oldConfiguration, to: candidate)
      runtimeIssueCodes.remove(.configurationRollbackFailed)
      return
    }

    let configuredOldDesired = desiredHotkeys(for: oldConfiguration)
    let oldDesired = configuredOldDesired.filter { registeredHotkeyIDs.contains($0.key) }
    let preservedConflictKeyCodes = remappedPreservedConflictKeyCodes(
      from: oldConfiguration,
      to: candidate
    )
    let preservedConflictIDs = Set(preservedConflictKeyCodes.compactMap {
      candidate.bindings[$0]?.id
    })
    let newDesired = desiredHotkeys(for: candidate).filter { id, _ in
      guard case .direct(let bindingID) = id else { return true }
      return !preservedConflictIDs.contains(bindingID)
    }
    let oldDirectConflictKeyCodes = directConflictKeyCodes
    var assignments: [HotkeyID: HotkeyID] = [:]
    var usedOldIDs = Set<HotkeyID>()
    var stagedIDs: [HotkeyID] = []
    var isolatedFailureIDs = Set<HotkeyID>()
    var resultingConflictKeyCodes = preservedConflictKeyCodes
    defer { transactionSuppressedHotkeyIDs.removeAll() }

    // First retain registrations whose logical identity and combination are
    // unchanged. They continue routing against the committed configuration
    // throughout the potentially slow repository write.
    for destinationID in newDesired.keys.sorted(by: hotkeyIDSort) {
      guard let hotkey = newDesired[destinationID], oldDesired[destinationID] == hotkey else {
        continue
      }
      assignments[destinationID] = destinationID
      usedOldIDs.insert(destinationID)
    }

    // Reuse any existing physical registration that already owns the desired
    // combination (for moves, swaps, and panel/direct transfers). Otherwise
    // preflight-register under an unrouted temporary ID. Temporary callbacks
    // are suppressed, while every old logical route remains live.
    for destinationID in newDesired.keys.sorted(by: hotkeyIDSort)
    where !assignments.values.contains(destinationID) {
      guard let hotkey = newDesired[destinationID] else { continue }
      if let sourceID = oldDesired.keys.sorted(by: hotkeyIDSort).first(where: {
        !usedOldIDs.contains($0) && oldDesired[$0] == hotkey
      }) {
        assignments[sourceID] = destinationID
        usedOldIDs.insert(sourceID)
        continue
      }

      let stagingID = makeStagingHotkeyID()
      transactionSuppressedHotkeyIDs.insert(stagingID)
      do {
        try await registrar.register(hotkey, id: stagingID)
        stagedIDs.append(stagingID)
        assignments[stagingID] = destinationID
      } catch {
        if canIsolateUnchangedDirectRegistrationFailure(
          id: destinationID,
          hotkey: hotkey,
          oldConfiguration: oldConfiguration,
          candidate: candidate
        ) {
          isolatedFailureIDs.insert(destinationID)
          if case .direct(let bindingID) = destinationID,
            let keyCode = candidate.keyCode(for: bindingID)
          {
            resultingConflictKeyCodes.insert(keyCode)
          }
          diagnosticsSink.record(code: "direct_hotkey_conflict_isolated", metadata: [:])
          continue
        }
        for stagedID in stagedIDs.reversed() { await registrar.unregister(id: stagedID) }
        throw contextualRegistrationError(
          error,
          id: destinationID,
          hotkey: hotkey,
          candidate: candidate
        )
      }
    }

    do {
      try await persistCandidate(candidate, restoring: oldConfiguration)
    } catch {
      for stagedID in stagedIDs.reversed() { await registrar.unregister(id: stagedID) }
      throw error
    }

    let effectiveNewDesired = newDesired.filter { !isolatedFailureIDs.contains($0.key) }
    // Suppress both sides of the short publication hand-off. The production
    // Carbon registrar validates the complete mapping, then swaps only its
    // in-memory routes and releases registrations no longer referenced.
    transactionSuppressedHotkeyIDs.formUnion(oldDesired.keys)
    transactionSuppressedHotkeyIDs.formUnion(effectiveNewDesired.keys)
    do {
      try await registrar.commitPreparedRegistrations(
        assignments: assignments,
        desiredHotkeys: effectiveNewDesired
      )
    } catch {
      var persistenceRollbackSucceeded = true
      do {
        try await repository.restore(oldConfiguration)
      } catch {
        persistenceRollbackSucceeded = false
      }
      if persistenceRollbackSucceeded {
        runtimeIssueCodes.remove(.configurationRollbackFailed)
      } else {
        runtimeIssueCodes.insert(.configurationRollbackFailed)
      }
      let failures = await rebuildHotkeyRegistrations(
        oldDesired,
        configuration: oldConfiguration,
        preservingConflicts: oldDirectConflictKeyCodes
      )
      updateRegistrationRecoveryIssues(for: failures)
      configuration = oldConfiguration
      if !persistenceRollbackSucceeded || !failures.isEmpty {
        throw LauncherError.hotkeyRecoveryIncomplete(
          reason: error.localizedDescription,
          failedCount: failures.count,
          persistenceRollbackSucceeded: persistenceRollbackSucceeded
        )
      }
      throw error
    }

    invalidKeyCodes = remappedInvalidKeyCodes(from: oldConfiguration, to: candidate)
    configuration = candidate
    configurationRevision &+= 1
    scheduleObsoleteWebsiteIconCleanups(from: oldConfiguration, to: candidate)
    registeredHotkeyIDs = Set(effectiveNewDesired.keys)
    directConflictKeyCodes = resultingConflictKeyCodes
    runtimeIssueCodes.remove(.panelHotkeyUnavailable)
    runtimeIssueCodes.remove(.registrationRecoveryIncomplete)
    runtimeIssueCodes.remove(.configurationRollbackFailed)
  }

  private func makeStagingHotkeyID() -> HotkeyID {
    .direct(bindingID: BindingID(
      rawValue: "__shortcut_launcher_stage_\(UUID().uuidString.lowercased())"
    ))
  }

  /// A filesystem API can report failure after an atomic rename has made the
  /// candidate visible (for example, when parent-directory fsync fails). Every
  /// failed save is therefore compensated before the caller reports that the
  /// old runtime graph remains active. If compensation also fails, the public
  /// result explicitly marks the on-disk state as uncertain.
  private func persistCandidate(
    _ candidate: LauncherConfiguration,
    restoring oldConfiguration: LauncherConfiguration
  ) async throws {
    do {
      try await repository.save(candidate)
      runtimeIssueCodes.remove(.configurationRollbackFailed)
    } catch {
      do {
        try await repository.restore(oldConfiguration)
        runtimeIssueCodes.remove(.configurationRollbackFailed)
      } catch {
        runtimeIssueCodes.insert(.configurationRollbackFailed)
        throw LauncherError.hotkeyRecoveryIncomplete(
          reason: error.localizedDescription,
          failedCount: 0,
          persistenceRollbackSucceeded: false
        )
      }
      throw error
    }
  }

  /// A conflict already observed at startup is runtime state, not a requested
  /// configuration change. Preserve it across unrelated edits and only retry it
  /// through the explicit single-binding retry action (or a pause/resume cycle).
  private func remappedPreservedConflictKeyCodes(
    from oldConfiguration: LauncherConfiguration,
    to candidate: LauncherConfiguration
  ) -> Set<UInt16> {
    guard oldConfiguration.directModeEnabled, candidate.directModeEnabled else {
      return []
    }
    return Set(directConflictKeyCodes.compactMap { oldKeyCode in
      guard let oldRecord = oldConfiguration.bindings[oldKeyCode],
        let newKeyCode = candidate.keyCode(for: oldRecord.id),
        candidate.bindings[newKeyCode]?.directHotkey == oldRecord.directHotkey
      else { return nil }
      return newKeyCode
    })
  }

  /// Restoring an unchanged, previously persisted shortcut after the global
  /// pause state changes is best-effort. A conflict is isolated to that binding;
  /// a newly created or edited combination remains transactional and fails the
  /// save so its old working state is retained.
  private func canIsolateUnchangedDirectRegistrationFailure(
    id: HotkeyID,
    hotkey: HotkeyDefinition,
    oldConfiguration: LauncherConfiguration,
    candidate: LauncherConfiguration
  ) -> Bool {
    guard case .direct(let bindingID) = id,
      oldConfiguration.binding(id: bindingID)?.directHotkey == hotkey,
      candidate.binding(id: bindingID)?.directHotkey == hotkey
    else { return false }
    return true
  }

  private func hotkeyIDSort(_ lhs: HotkeyID, _ rhs: HotkeyID) -> Bool {
    func value(_ id: HotkeyID) -> String {
      switch id {
      case .panel: "0-panel"
      case .direct(let bindingID): "1-\(bindingID.rawValue)"
      }
    }
    return value(lhs) < value(rhs)
  }

  private func remappedInvalidKeyCodes(
    from oldConfiguration: LauncherConfiguration,
    to newConfiguration: LauncherConfiguration
  ) -> Set<UInt16> {
    let unchangedInvalidIDs = Set(invalidKeyCodes.compactMap { keyCode -> BindingID? in
      guard let oldRecord = oldConfiguration.bindings[keyCode],
        newConfiguration.binding(id: oldRecord.id)?.target == oldRecord.target
      else { return nil }
      return oldRecord.id
    })
    return Set(newConfiguration.bindings.compactMap { keyCode, record in
      unchangedInvalidIDs.contains(record.id) ? keyCode : nil
    })
  }

  private func rebuildHotkeyRegistrations(
    _ desired: [HotkeyID: HotkeyDefinition],
    configuration: LauncherConfiguration,
    preservingConflicts: Set<UInt16>
  ) async -> Set<HotkeyID> {
    await registrar.unregisterAll()
    var restored = Set<HotkeyID>()
    var failures = Set<HotkeyID>()
    var conflicts = preservingConflicts

    for id in desired.keys.sorted(by: hotkeyIDSort) {
      guard let hotkey = desired[id] else { continue }
      do {
        try await registrar.register(hotkey, id: id)
        restored.insert(id)
      } catch {
        failures.insert(id)
        diagnosticsSink.record(code: "hotkey_recovery_failed", metadata: [:])
        if case .direct(let bindingID) = id,
          let keyCode = configuration.keyCode(for: bindingID)
        {
          conflicts.insert(keyCode)
        }
      }
    }
    registeredHotkeyIDs = restored
    directConflictKeyCodes = conflicts
    return failures
  }

  private func updateRegistrationRecoveryIssues(for failures: Set<HotkeyID>) {
    if failures.isEmpty {
      runtimeIssueCodes.remove(.registrationRecoveryIncomplete)
      runtimeIssueCodes.remove(.panelHotkeyUnavailable)
      return
    }
    runtimeIssueCodes.insert(.registrationRecoveryIncomplete)
    if failures.contains(.panel) {
      runtimeIssueCodes.insert(.panelHotkeyUnavailable)
    } else {
      runtimeIssueCodes.remove(.panelHotkeyUnavailable)
    }
  }

  private func contextualRegistrationError(
    _ error: Error,
    id: HotkeyID,
    hotkey: HotkeyDefinition,
    candidate: LauncherConfiguration
  ) -> Error {
    guard let launcherError = error as? LauncherError,
      case .hotkeyRegistrationFailed = launcherError
    else { return error }

    let target: String
    switch id {
    case .panel:
      target = "面板唤出"
    case .direct(let bindingID):
      target = candidate.binding(id: bindingID)
        .map(privacySafeDisplayName(for:)) ?? "该绑定"
    }
    return LauncherError.hotkeyUnavailable(
      target: target,
      combination: hotkeyDisplayName(hotkey)
    )
  }

  private func validationIssue(
    for error: Error,
    configuration: LauncherConfiguration
  ) -> LauncherIssue {
    guard let launcherError = error as? LauncherError else {
      return LauncherIssue(code: .invalidConfiguration)
    }
    switch launcherError {
    case .invalidHotkey:
      return LauncherIssue(code: .invalidHotkey)
    case .hotkeyConflict(let combination):
      let matches = configuration.bindings.values.filter {
        $0.directHotkey?.displayName == combination
      }.sorted {
        $0.id.rawValue < $1.id.rawValue
      }
      if let panelConflict = matches.first(where: {
        $0.directHotkey == configuration.panelHotkey
      }) {
        return LauncherIssue(
          code: .panelHotkeyConflict,
          bindingID: panelConflict.id,
          combination: panelConflict.directHotkey
        )
      }
      return LauncherIssue(
        code: .duplicateHotkey,
        bindingID: matches.first?.id,
        relatedBindingID: matches.dropFirst().first?.id,
        combination: matches.first?.directHotkey
      )
    case .unsupportedURLScheme, .invalidURL, .targetUnavailable:
      return LauncherIssue(code: .invalidTarget)
    default:
      return LauncherIssue(code: .invalidConfiguration)
    }
  }

  private func commitFailureResult(
    for error: Error,
    configuration: LauncherConfiguration
  ) -> LauncherCommitResult {
    guard let launcherError = error as? LauncherError else {
      return .persistenceFailed(code: .writeFailed)
    }
    switch launcherError {
    case .hotkeyUnavailable(_, let combination), .hotkeyConflict(let combination):
      let match = configuration.bindings.values.first {
        guard let hotkey = $0.directHotkey else { return false }
        return hotkey.displayName == combination
          || keyLabelSnapshot.displayName(for: hotkey) == combination
      }
      let hotkey = match?.directHotkey ?? configuration.panelHotkey
      return .registrationFailed(
        bindingID: match?.id.hostSafeProjection,
        combination: hotkey
      )
    case .hotkeyRegistrationFailed:
      return .registrationFailed(bindingID: nil, combination: configuration.panelHotkey)
    case .hotkeyRecoveryIncomplete(_, _, let persistenceRollbackSucceeded):
      return .persistenceFailed(
        code: persistenceRollbackSucceeded ? .recoveryIncomplete : .rollbackFailed
      )
    case .configurationWriteFailed:
      return .persistenceFailed(code: .writeFailed)
    case .configurationReadFailed:
      return .persistenceFailed(code: .readFailed)
    case .invalidHotkey, .invalidURL, .unsupportedURLScheme, .invalidConfiguration,
      .unsupportedFutureSchema, .importInvalid, .importTooLarge, .targetUnavailable:
      return .validationFailed([validationIssue(for: launcherError, configuration: configuration)])
    default:
      return .rejected(reason: .moduleUnavailable)
    }
  }

  private func report(_ error: Error, prefix: String? = nil) {
    let message = [prefix, userFacingDescription(for: error)].compactMap { $0 }
      .joined(separator: "：")
    statusText = message
    errorMessage = message
    logger.error("launcher_error: \(error.localizedDescription, privacy: .private)")
  }

  /// Errors from bookmark, file I/O, and Workspace APIs can contain absolute
  /// paths. Keep those details in the private log while presenting stable,
  /// actionable copy to the user and to an embedding host.
  private func userFacingDescription(for error: Error) -> String {
    guard let launcherError = error as? LauncherError else {
      return "操作未完成，请重试；如果问题持续，请重新选择目标。"
    }
    switch launcherError {
    case .bookmarkCreationFailed:
      return "无法保存所选目标的访问权限，请重新选择目标。"
    case .bookmarkResolveFailed, .targetUnavailable:
      return "目标已移动、删除或权限失效，请重新定位。"
    case .configurationReadFailed:
      return "无法读取快捷启动配置，请检查存储目录权限后重试。"
    case .configurationWriteFailed:
      return "无法保存快捷启动配置，请检查存储目录权限后重试。"
    case .targetOpenFailed:
      return "系统无法打开该目标，请确认目标仍然可用。"
    case .hotkeyRecoveryIncomplete(_, let failedCount, let persistenceRollbackSucceeded):
      if persistenceRollbackSucceeded {
        return "保存失败，磁盘配置已恢复；仍有 \(failedCount) 个快捷键需要从菜单栏暂停后再恢复。"
      }
      return "保存失败，当前会话已回到保存前状态，但磁盘配置未能回滚。请先检查存储目录权限再重新保存；另有 \(failedCount) 个快捷键可能需要暂停后恢复。"
    default:
      return launcherError.localizedDescription
    }
  }

  /// Refreshes a stale bookmark only after the OS has accepted the open
  /// request. A refresh failure is deliberately non-blocking: it must not turn
  /// an already successful execution into a user-visible open failure.
  private func refreshStaleBookmark(
    bindingID: BindingID,
    originalTarget: LaunchTarget,
    resolvedURL: URL
  ) async -> Bool {
    guard let activeKeyCode = configuration.keyCode(for: bindingID),
      var activeRecord = configuration.bindings[activeKeyCode],
      activeRecord.target == originalTarget,
      editingSession == nil,
      !isCommitting,
      lifecycleOperation == .idle
    else {
      diagnosticsSink.record(code: "stale_bookmark_refresh_discarded", metadata: [:])
      return true
    }

    let expectedRevision = configurationRevision
    isCommitting = true
    defer { finishConfigurationTransaction() }

    do {
      activeRecord.target.bookmarkData = try bookmarkResolver.makeBookmark(for: resolvedURL)
      activeRecord.target.lastKnownURL = resolvedURL
      var candidate = configuration
      candidate.bindings[activeKeyCode] = activeRecord
      try ConfigurationValidator.validate(candidate)
      try await persistCandidate(candidate, restoring: configuration)
      guard configurationRevision == expectedRevision,
        configuration.bindings[activeKeyCode]?.target == originalTarget
      else {
        diagnosticsSink.record(code: "stale_bookmark_refresh_discarded", metadata: [:])
        return true
      }
      configuration = candidate
      configurationRevision &+= 1
      diagnosticsSink.record(code: "stale_bookmark_refreshed", metadata: [:])
      return true
    } catch {
      diagnosticsSink.record(code: "stale_bookmark_refresh_failed", metadata: [:])
      logger.error("stale_bookmark_refresh_failed")
      return false
    }
  }

  private func displayName(for url: URL, kind: LaunchTargetKind) -> String {
    switch kind {
    case .application:
      let bundle = Bundle(url: url)
      let localizedName = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle?.localizedInfoDictionary?["CFBundleName"] as? String
        ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle?.infoDictionary?["CFBundleName"] as? String
      return normalizedPreferredDisplayName(localizedName)
        ?? url.deletingPathExtension().lastPathComponent
    case .file, .folder: return url.lastPathComponent
    case .web: return url.host ?? url.absoluteString
    }
  }

  private func normalizedPreferredDisplayName(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func privacySafeDisplayName(for record: BindingRecord) -> String {
    BindingRuntimeSummary(
      bindingID: record.id,
      slotKeyCode: record.physicalKeyCode,
      targetKind: record.target.kind,
      displayName: record.target.displayName,
      runtimeState: .targetUnavailable(hotkey: record.directHotkey)
    ).displayName ?? record.target.kind.displayName
  }

  private func resumeQuickBinding(
    sessionID: UUID,
    expectedConfigurationRevision: UInt64,
    pendingTarget: QuickBindingPendingTarget?
  ) {
    guard let activeSession = quickBindingSession,
      activeSession.id == sessionID
    else { return }
    quickBindingSession = QuickBindingSession(
      id: activeSession.id,
      keyCode: activeSession.keyCode,
      expectedConfigurationRevision: expectedConfigurationRevision,
      phase: .choosingTarget,
      pendingTarget: pendingTarget,
      chooserSnapshot: activeSession.chooserSnapshot
    )
  }

  private func quickBindingRejectionMessage(
    _ reason: LauncherCommitRejectionReason
  ) -> String {
    switch reason {
    case .moduleUnavailable:
      "快捷启动模块当前不可用，请稍后再试。"
    case .moduleStopping:
      "快捷键正在暂停，请完成后再试。"
    case .transactionInProgress:
      "另一项修改正在保存，请稍后再试。"
    case .staleRevision:
      "配置刚刚发生变化，请重新选择一次目标。"
    case .noChanges:
      "这个绑定没有变化。"
    }
  }

  private func websiteIconRequest(
    for keyCode: UInt16,
    reason: WebsiteIconRequest.Reason
  ) -> WebsiteIconRequest? {
    guard let record = configuration.bindings[keyCode], record.target.kind == .web else {
      return nil
    }
    return WebsiteIconRequest(
      bindingID: record.id,
      websiteURL: record.target.lastKnownURL,
      reason: reason
    )
  }

  private func beginWebsiteIconLoad(
    for record: BindingRecord,
    reason: WebsiteIconRequest.Reason
  ) {
    guard record.target.kind == .web else { return }
    let provider = websiteIconProvider
    let request = WebsiteIconRequest(
      bindingID: record.id,
      websiteURL: record.target.lastKnownURL,
      reason: reason
    )
    Task(priority: .utility) {
      _ = await provider.icon(for: request)
    }
  }

  /// Keeps an old custom asset through the visible undo window. The cleanup
  /// re-checks the current BindingID and origin, so undo or a newer edit wins.
  private func scheduleCustomWebsiteIconCleanup(for record: BindingRecord) {
    guard record.target.kind == .web,
      websiteIconProvider is any WebsiteIconManaging
    else { return }
    websiteIconCleanupTasks[record.id]?.cancel()
    let generation = UUID()
    websiteIconCleanupGenerations[record.id] = generation
    websiteIconCleanupTasks[record.id] = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard !Task.isCancelled,
        let self,
        self.websiteIconCleanupGenerations[record.id] == generation
      else { return }

      let oldOrigin = try? WebsiteOrigin(websiteURL: record.target.lastKnownURL)
      let originIsStillInUse = self.configuration.bindings.values.contains { current in
        guard current.id == record.id,
          current.target.kind == .web,
          let currentOrigin = try? WebsiteOrigin(websiteURL: current.target.lastKnownURL)
        else { return false }
        return currentOrigin == oldOrigin
      }
      if !originIsStillInUse,
        let iconManager = self.websiteIconProvider as? any WebsiteIconManaging
      {
        let request = WebsiteIconRequest(
          bindingID: record.id,
          websiteURL: record.target.lastKnownURL,
          reason: .passiveDisplay
        )
        if let mutation = try? await iconManager.removeCustomIcon(for: request) {
          await iconManager.finalizeCustomIconMutation(mutation)
        }
      }
      guard self.websiteIconCleanupGenerations[record.id] == generation else { return }
      self.websiteIconCleanupTasks[record.id] = nil
      self.websiteIconCleanupGenerations[record.id] = nil
    }
  }

  /// Reconciles user-owned icon assets after every successful configuration
  /// publication, including import and advanced batch edits. A delayed cleanup
  /// retains the previous asset through the visible undo window and re-checks
  /// the current BindingID/origin before deleting anything.
  private func scheduleObsoleteWebsiteIconCleanups(
    from oldConfiguration: LauncherConfiguration,
    to newConfiguration: LauncherConfiguration
  ) {
    for oldRecord in oldConfiguration.bindings.values where oldRecord.target.kind == .web {
      let oldOrigin = try? WebsiteOrigin(websiteURL: oldRecord.target.lastKnownURL)
      let newOrigin = newConfiguration.binding(id: oldRecord.id).flatMap { record -> WebsiteOrigin? in
        guard record.target.kind == .web else { return nil }
        return try? WebsiteOrigin(websiteURL: record.target.lastKnownURL)
      }
      if newOrigin != oldOrigin {
        scheduleCustomWebsiteIconCleanup(for: oldRecord)
      }
    }
  }

  private func publishFeedback(
    kind: LauncherFeedbackKind,
    message: String,
    slotKeyCode: UInt16? = nil,
    undoToken: LauncherUndoToken? = nil
  ) {
    let event = LauncherFeedbackEvent(
      kind: kind,
      message: message,
      slotKeyCode: slotKeyCode,
      undoToken: undoToken
    )
    guard feedbackEvent == nil else {
      if let slotKeyCode {
        feedbackQueue.removeAll { $0.slotKeyCode == slotKeyCode }
      }
      feedbackQueue.append(event)
      if feedbackQueue.count > 3 {
        feedbackQueue.removeFirst(feedbackQueue.count - 3)
      }
      return
    }
    presentFeedback(event)
  }

  private func presentFeedback(_ event: LauncherFeedbackEvent) {
    feedbackDismissTask?.cancel()
    feedbackEvent = event
    if let application = NSApp {
      NSAccessibility.post(
        element: application,
        notification: .announcementRequested,
        userInfo: [
          .announcement: event.message,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ]
      )
    }
    let lifetime: UInt64 = event.undoToken == nil ? 2_000_000_000 : 5_000_000_000
    feedbackDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: lifetime)
      guard !Task.isCancelled, self?.feedbackEvent?.id == event.id else { return }
      self?.feedbackEvent = nil
      self?.feedbackDismissTask = nil
      self?.presentNextFeedbackIfNeeded()
    }
  }

  private func presentNextFeedbackIfNeeded() {
    guard feedbackEvent == nil, !feedbackQueue.isEmpty else { return }
    presentFeedback(feedbackQueue.removeFirst())
  }

  private func elapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now >= startedAt else { return 0 }
    return (now - startedAt) / 1_000_000
  }

  private var bindingStateInputSnapshot: BindingStateInputSnapshot {
    let unavailableBindingIDs = Set(invalidKeyCodes.compactMap {
      configuration.bindings[$0]?.id
    })
    return BindingStateInputSnapshot(
      committedConfiguration: configuration,
      editSession: editingSession,
      registrationLedger: rawRegistrationLedgerSnapshot,
      unavailableTargetBindingIDs: unavailableBindingIDs,
      keyLabels: keyLabelSnapshot
    )
  }
}

extension UTType {
  fileprivate static let shortcutLauncherConfiguration = UTType(
    exportedAs: "io.github.miseon-stack.shortcutlauncher.configuration",
    conformingTo: .json
  )
}
