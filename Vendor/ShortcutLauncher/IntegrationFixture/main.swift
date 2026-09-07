import AppKit
import Foundation
import ShortcutLauncherCore
import ShortcutLauncherUI

@main
struct ShortcutLauncherIntegrationFixture {
  private static let smokeArgument = "--smoke"

  static func main() async {
    guard CommandLine.arguments.dropFirst().contains(smokeArgument) else {
      printHelp()
      return
    }

    do {
      try await runSmokeTest()
    } catch {
      FileHandle.standardError.write(
        Data("integration fixture failed: \(error.localizedDescription)\n".utf8)
      )
      exit(EXIT_FAILURE)
    }
  }

  /// Exercises the public second-host seam without registering a real global
  /// hotkey, opening a real URL, or reading the user's launcher configuration.
  @MainActor
  private static func runSmokeTest() async throws {
    let fileManager = FileManager.default
    let storageDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(
        "shortcut-launcher-integration-fixture-\(UUID().uuidString)",
        isDirectory: true
      )
    try fileManager.createDirectory(
      at: storageDirectory,
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: storageDirectory) }

    let registrar = FixtureHotkeyRegistrar()
    let opener = FixtureWorkspaceOpener()
    let eventSink = FixtureEventSink()
    let panelPresenter = FixturePanelPresenter()
    let initialUIPreferences = LauncherUIPreferences(
      onlineWebsiteIconsEnabled: false,
      appearance: .dark,
      onboardingVersion: 2
    )
    let uiPreferencesStore = FixtureUIPreferencesStore(
      directory: storageDirectory,
      initialPreferences: initialUIPreferences
    )
    let fixtureApplication = ApplicationDescriptor(
      displayName: "Fixture Browser",
      bundleIdentifier: "invalid.fixture.browser",
      url: storageDirectory.appendingPathComponent("Fixture Browser.app", isDirectory: true),
      searchAliases: ["fixture", "browser"]
    )
    let applicationCatalog = FixtureApplicationCatalog(applications: [fixtureApplication])
    let websiteIconProvider = FixtureWebsiteIconProvider()
    let fixtureIconData = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    let fixtureIconURL = storageDirectory.appendingPathComponent(
      "host-owned-fixture-icon.png",
      isDirectory: false
    )
    try fixtureIconData.write(to: fixtureIconURL, options: .atomic)
    let websiteIconImagePicker = FixtureWebsiteIconImagePicker(selectedURL: fixtureIconURL)
    let fixtureTheme = LauncherTheme(
      title: "Fixture Launcher",
      subtitle: "Injected by the second host",
      lockedAppearance: .light,
      panelPadding: 28,
      cornerRadius: 20,
      motionDuration: 0
    )
    let uiConfiguration = ShortcutLauncherUIConfiguration(
      theme: fixtureTheme,
      preferencesStore: uiPreferencesStore,
      applicationCatalog: applicationCatalog,
      websiteIconProvider: websiteIconProvider,
      websiteIconImagePicker: websiteIconImagePicker
    )
    let repository = ConfigurationRepository(storageDirectory: storageDirectory)
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: FoundationBookmarkResolver(),
      opener: opener,
      bookmarkPolicy: .lastKnownURLOnly,
      eventSink: eventSink,
      initialPanelHotkey: HotkeyDefinition(
        keyCode: 24,
        modifiers: [.command, .option, .control, .shift]
      ),
      ownerLease: HotkeyOwnerLease(),
      panelPresenterFactory: { _ in panelPresenter },
      uiPreferencesStore: uiConfiguration.preferencesStore,
      launcherTheme: uiConfiguration.theme,
      applicationCatalog: uiConfiguration.applicationCatalog,
      websiteIconProvider: uiConfiguration.websiteIconProvider,
      websiteIconImagePicker: uiConfiguration.websiteIconImagePicker
    )
    let controller: any ShortcutLauncherControlling = module

    try require(
      repository.configurationURL.deletingLastPathComponent() == storageDirectory,
      "fixture repository must be isolated in its unique temporary directory"
    )
    try require(
      uiPreferencesStore.preferencesURL.deletingLastPathComponent() == storageDirectory,
      "the injected UI preferences boundary must expose only fixture-local URLs"
    )
    try require(
      controller.snapshot.lifecycleState == .stopped,
      "new module must begin stopped"
    )

    var didStart = false
    do {
      try await controller.start()
      didStart = true

      let initialSnapshot = controller.snapshot
      try require(
        initialSnapshot.lifecycleState == .running,
        "start must publish the running state"
      )
      try require(
        initialSnapshot.bindings.count == KeySlotCatalog.all.count,
        "snapshot must project every launcher slot"
      )
      try require(
        registrar.registrations[.panel] == initialSnapshot.panelHotkey,
        "start must register the configured panel hotkey through the injected registrar"
      )
      try require(
        module.launcherTheme.title == "Fixture Launcher"
          && module.launcherTheme.subtitle == "Injected by the second host"
          && module.launcherTheme.lockedAppearance == .light
          && module.launcherTheme.panelPadding == 28
          && module.launcherTheme.cornerRadius == 20
          && module.launcherTheme.motionDuration == 0,
        "the module must retain the second host's injected launcher theme"
      )
      try require(
        module.uiPreferences == initialUIPreferences,
        "start must load UI-only preferences from the injected store"
      )
      let preferenceStateAfterStart = await uiPreferencesStore.snapshot()
      try require(
        preferenceStateAfterStart.loadCount == 1
          && preferenceStateAfterStart.saveCount == 0
          && preferenceStateAfterStart.preferences == initialUIPreferences,
        "UI preferences must remain inside the host-owned in-memory store"
      )
      await applicationCatalog.waitUntilPrewarmed()
      let catalogStateAfterStart = await applicationCatalog.snapshot()
      try require(
        catalogStateAfterStart.prewarmCount == 1,
        "start must prewarm the injected application catalog"
      )
      let applicationResults = await module.applicationCatalog.search(
        query: "fixture",
        limit: 1
      )
      try require(
        applicationResults == [fixtureApplication],
        "application search must route through the host's fixed catalog"
      )
      let catalogStateAfterSearch = await applicationCatalog.snapshot()
      try require(
        catalogStateAfterSearch.searches == [
          FixtureApplicationCatalog.Search(query: "fixture", limit: 1)
        ],
        "the injected catalog must receive the host query without scanning application folders"
      )
      let iconStateAfterStart = await websiteIconProvider.snapshot()
      try require(
        iconStateAfterStart.onlineFetchingChanges == [false],
        "the injected icon provider must receive the loaded offline preference"
      )

      controller.presentPanel()
      try require(
        panelPresenter.isVisible && panelPresenter.showCount == 1,
        "the public host contract must present through the injected panel boundary"
      )
      controller.dismissPanel()
      try require(
        !panelPresenter.isVisible && panelPresenter.dismissCount == 1,
        "the public host contract must dismiss through the injected panel boundary"
      )

      let missingBindingID = BindingID(rawValue: "integration-fixture-missing-binding")
      let missingExecution = await controller.executeWithResult(
        bindingID: missingBindingID,
        source: .panelClick
      )
      try require(
        missingExecution == .failed(missingBindingID, code: .noBinding),
        "the public host contract must return a structured missing-binding execution result"
      )
      let missingRetry = await controller.retryDirectHotkey(bindingID: missingBindingID)
      try require(
        missingRetry == .notConfigured(missingBindingID),
        "the public host contract must return a structured not-configured retry result"
      )

      let bindingID = BindingID(rawValue: "integration-fixture-web-binding")
      let secretMarker = "private-fixture-token-7c9b"
      let targetURL = try requireURL(
        "https://fixture.invalid/open?token=\(secretMarker)#private"
      )
      let target = LaunchTarget(
        kind: .web,
        displayName: targetURL.absoluteString,
        lastKnownURL: targetURL
      )
      let directHotkey = HotkeyDefinition(
        keyCode: 13,
        modifiers: [.command, .option]
      )
      let binding = BindingRecord(
        id: bindingID,
        physicalKeyCode: PhysicalKeyCode.q,
        target: target,
        directHotkey: directHotkey
      )
      let activeConfiguration = LauncherConfiguration(
        panelHotkey: initialSnapshot.panelHotkey,
        directModeEnabled: true,
        bindings: [PhysicalKeyCode.q: binding]
      )

      let activationResult = await controller.commit(
        LauncherCommitRequest(
          expectedConfigurationRevision: initialSnapshot.configurationRevision,
          candidateConfiguration: activeConfiguration
        )
      )
      let activeRevision: UInt64
      switch activationResult {
      case .committed(let revision, let enabled):
        activeRevision = revision
        try require(
          revision > initialSnapshot.configurationRevision,
          "a successful host commit must advance the public revision"
        )
        try require(
          enabled == [bindingID],
          "the commit result must identify the enabled direct binding"
        )
      default:
        throw FixtureFailure(message: "public host commit did not activate the fixture binding")
      }

      try require(
        registrar.registrations[.direct(bindingID: bindingID)] == directHotkey,
        "the active configuration must register its direct hotkey"
      )
      guard
        let bindingSummary = controller.snapshot.bindings.first(where: {
          $0.bindingID == bindingID
        })
      else {
        throw FixtureFailure(message: "snapshot must expose the committed binding identity")
      }
      try require(
        bindingSummary.displayName == LaunchTargetKind.web.displayName,
        "snapshot must replace a URL-like display name with its privacy-safe kind label"
      )

      await module.refreshWebsiteIcon(for: PhysicalKeyCode.q)
      var iconState = await websiteIconProvider.snapshot()
      try require(
        iconState.refreshRequests.last
          == WebsiteIconRequest(
            bindingID: bindingID,
            websiteURL: targetURL,
            reason: .userRefresh
          ),
        "manual refresh must use the injected website icon provider"
      )
      await module.backfillWebsiteIcons()
      iconState = await websiteIconProvider.snapshot()
      try require(
        iconState.iconRequests.contains(
          WebsiteIconRequest(
            bindingID: bindingID,
            websiteURL: targetURL,
            reason: .explicitBackfill
          )
        ),
        "icon backfill must remain inside the host's non-network provider"
      )
      await module.chooseCustomWebsiteIcon(for: PhysicalKeyCode.q)
      iconState = await websiteIconProvider.snapshot()
      try require(
        websiteIconImagePicker.chooseCount == 1
          && websiteIconImagePicker.receivedNilPresentationWindow
          && iconState.customStoreRequests.count == 1
          && iconState.customStoreRequests[0].imageData == fixtureIconData
          && iconState.customStoreRequests[0].request.bindingID == bindingID,
        "custom-icon selection must use the injected picker and provider only"
      )
      await module.clearAutomaticWebsiteIconCache()
      iconState = await websiteIconProvider.snapshot()
      try require(
        iconState.clearAutomaticCacheCount == 1,
        "cache maintenance must use the injected provider"
      )

      let appearanceWasSaved = await module.setAppearance(.light)
      try require(
        appearanceWasSaved,
        "appearance changes must save through the injected UI preferences store"
      )
      let onlineIconPreferenceWasSaved = await module.setOnlineWebsiteIconsEnabled(true)
      try require(
        onlineIconPreferenceWasSaved,
        "online-icon preference changes must save through the injected UI preferences store"
      )
      let updatedUIPreferences = LauncherUIPreferences(
        onlineWebsiteIconsEnabled: true,
        appearance: .light,
        onboardingVersion: 2
      )
      let preferenceStateAfterUpdates = await uiPreferencesStore.snapshot()
      try require(
        module.uiPreferences == updatedUIPreferences
          && preferenceStateAfterUpdates.preferences == updatedUIPreferences
          && preferenceStateAfterUpdates.saveCount == 2,
        "UI-only preference writes must not fall back to a user-directory repository"
      )
      iconState = await websiteIconProvider.snapshot()
      try require(
        iconState.onlineFetchingChanges == [false, true],
        "online-icon policy changes must be forwarded to the injected provider"
      )

      let executionResult = await controller.executeWithResult(
        bindingID: bindingID,
        source: .panelClick
      )
      try require(
        executionResult == .accepted(bindingID),
        "the injected opener must produce a structured accepted execution result"
      )
      try require(
        opener.requests.count == 1 && opener.requests[0].resolvedURL == targetURL,
        "execution must route the committed target to the injected opener"
      )

      let executionEvents = eventSink.events.filter {
        $0.name == .bindingExecuted && $0.bindingID == bindingID
      }
      try require(executionEvents.count == 1, "accepted execution must publish one event")
      guard let executionEvent = executionEvents.first else {
        throw FixtureFailure(message: "accepted execution event is missing")
      }
      try require(
        executionEvent.targetKind == .web
          && executionEvent.triggerSource == .panelClick
          && executionEvent.resultCode == "accepted"
          && executionEvent.configurationRevision == activeRevision
          && executionEvent.durationMilliseconds != nil,
        "execution event must expose stable structured metadata"
      )

      let reflectedEvents = eventSink.events.map { String(reflecting: $0) }.joined()
      try require(
        !reflectedEvents.contains(secretMarker)
          && !reflectedEvents.contains(targetURL.absoluteString)
          && !reflectedEvents.contains(storageDirectory.path(percentEncoded: false)),
        "public events must not expose target URLs, tokens, or configuration paths"
      )

      var pausedConfiguration = activeConfiguration
      pausedConfiguration.directModeEnabled = false
      let pauseResult = await controller.commit(
        LauncherCommitRequest(
          expectedConfigurationRevision: activeRevision,
          candidateConfiguration: pausedConfiguration
        )
      )
      let pausedRevision: UInt64
      switch pauseResult {
      case .committed(let revision, let enabled):
        pausedRevision = revision
        try require(revision > activeRevision, "pause commit must advance the revision")
        try require(enabled.isEmpty, "pause commit must report no enabled direct bindings")
      default:
        throw FixtureFailure(message: "revision-aware pause commit was not accepted")
      }
      try require(
        controller.snapshot.configurationRevision == pausedRevision
          && controller.snapshot.directHotkeysPaused,
        "paused state and revision must be visible to the host snapshot"
      )
      try require(
        registrar.registrations[.direct(bindingID: bindingID)] == nil,
        "pausing must unregister the direct hotkey while retaining the panel hotkey"
      )

      let staleCommit = await controller.commit(
        LauncherCommitRequest(
          expectedConfigurationRevision: activeRevision,
          candidateConfiguration: activeConfiguration
        )
      )
      try require(
        staleCommit == .rejected(reason: .staleRevision),
        "a host write based on an old snapshot must be rejected"
      )

      await controller.stop()
      didStart = false
      try require(
        controller.snapshot.lifecycleState == .stopped,
        "stop must publish the stopped state"
      )
      try require(
        registrar.registrations.isEmpty && registrar.shutdownCount == 1,
        "stop must release every injected registration and shut the registrar down"
      )
      try require(
        panelPresenter.invalidateCount == 1,
        "stop must invalidate the injected panel boundary"
      )
      let catalogStateAfterStop = await applicationCatalog.snapshot()
      try require(
        catalogStateAfterStop.invalidateCount == 1,
        "stop must invalidate the injected application catalog"
      )
      let iconStateAfterStop = await websiteIconProvider.snapshot()
      try require(
        iconStateAfterStop.cancelCount == 1,
        "stop must cancel the injected website icon provider"
      )
      let preferenceStateAfterStop = await uiPreferencesStore.snapshot()
      try require(
        preferenceStateAfterStop.loadCount == 1
          && preferenceStateAfterStop.saveCount == 2
          && preferenceStateAfterStop.restoreCount == 0,
        "the injected UI preferences lifecycle must be deterministic"
      )

      let postStopResult = await controller.executeWithResult(
        bindingID: bindingID,
        source: .directHotkey
      )
      try require(
        postStopResult == .failed(bindingID, code: .moduleUnavailable),
        "execution after stop must return moduleUnavailable"
      )
      try require(
        opener.requests.count == 1,
        "execution after stop must not invoke the opener"
      )

      let persisted = try await repository.load()
      try require(
        persisted.configuration == pausedConfiguration,
        "the isolated repository must retain the last accepted host commit"
      )
    } catch {
      if didStart { await controller.stop() }
      throw error
    }

    try fileManager.removeItem(at: storageDirectory)
    try require(
      !fileManager.fileExists(atPath: storageDirectory.path(percentEncoded: false)),
      "temporary storage must be removed after the lifecycle completes"
    )

    print("ShortcutLauncher second-host smoke test passed.")
  }

  private static func requireURL(_ rawValue: String) throws -> URL {
    guard let url = URL(string: rawValue) else {
      throw FixtureFailure(message: "fixture URL could not be constructed")
    }
    return url
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    guard condition() else { throw FixtureFailure(message: message) }
  }

  private static func printHelp() {
    print(
      """
      ShortcutLauncherIntegrationFixture

      A second-host contract fixture for ShortcutLauncher's public and injectable APIs.

      Usage:
        swift run ShortcutLauncherIntegrationFixture --smoke

      Smoke mode uses injected platform/UI fakes plus a unique temporary configuration
      directory. It never registers a real global hotkey, opens a real target, scans the
      user's applications, requests the network, opens a system image picker, or reads
      the user's launcher configuration. All temporary files are removed on exit.
      """
    )
  }
}

@MainActor
private final class FixtureHotkeyRegistrar: HotkeyRegistering {
  private var handler: (@MainActor @Sendable (HotkeyID) -> Void)?
  private(set) var registrations: [HotkeyID: HotkeyDefinition] = [:]
  private(set) var shutdownCount = 0

  func setHandler(_ handler: @escaping @MainActor @Sendable (HotkeyID) -> Void) {
    self.handler = handler
  }

  func register(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    registrations[id] = hotkey
  }

  func replace(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    registrations[id] = hotkey
  }

  func reassign(
    _ hotkey: HotkeyDefinition,
    from oldID: HotkeyID,
    to newID: HotkeyID
  ) async throws {
    registrations.removeValue(forKey: oldID)
    registrations[newID] = hotkey
  }

  func commitPreparedRegistrations(
    assignments: [HotkeyID: HotkeyID],
    desiredHotkeys: [HotkeyID: HotkeyDefinition]
  ) async throws {
    guard Set(assignments.values).count == assignments.count,
      Set(assignments.values) == Set(desiredHotkeys.keys)
    else { throw FixtureFailure(message: "invalid prepared registration mapping") }
    var next: [HotkeyID: HotkeyDefinition] = [:]
    for (sourceID, destinationID) in assignments {
      guard registrations[sourceID] == desiredHotkeys[destinationID] else {
        throw FixtureFailure(message: "stale prepared registration mapping")
      }
      next[destinationID] = desiredHotkeys[destinationID]
    }
    registrations = next
  }

  func unregister(id: HotkeyID) async {
    registrations.removeValue(forKey: id)
  }

  func unregisterAll() async {
    registrations.removeAll()
  }

  func shutdown() async {
    shutdownCount += 1
    registrations.removeAll()
    handler = nil
  }
}

@MainActor
private final class FixtureWorkspaceOpener: WorkspaceOpening {
  struct Request {
    let target: LaunchTarget
    let resolvedURL: URL
  }

  private(set) var requests: [Request] = []

  func open(target: LaunchTarget, resolvedURL: URL) async throws {
    requests.append(Request(target: target, resolvedURL: resolvedURL))
  }
}

private struct FixtureUIPreferencesStoreSnapshot: Sendable {
  let preferences: LauncherUIPreferences
  let loadCount: Int
  let saveCount: Int
  let restoreCount: Int
}

private actor FixtureUIPreferencesStore: LauncherUIPreferencesStoring {
  nonisolated let preferencesURL: URL
  nonisolated let backupURL: URL

  private var preferences: LauncherUIPreferences
  private var loadCount = 0
  private var saveCount = 0
  private var restoreCount = 0

  init(directory: URL, initialPreferences: LauncherUIPreferences) {
    preferencesURL = directory.appendingPathComponent(
      "fixture-ui-preferences.json",
      isDirectory: false
    )
    backupURL = directory.appendingPathComponent(
      "fixture-ui-preferences.backup.json",
      isDirectory: false
    )
    preferences = initialPreferences
  }

  func load() async throws -> LauncherUIPreferencesLoadResult {
    loadCount += 1
    return LauncherUIPreferencesLoadResult(preferences: try preferences.validated())
  }

  func save(_ preferences: LauncherUIPreferences) async throws {
    self.preferences = try preferences.validated()
    saveCount += 1
  }

  func restore(_ preferences: LauncherUIPreferences) async throws {
    self.preferences = try preferences.validated()
    restoreCount += 1
  }

  func snapshot() -> FixtureUIPreferencesStoreSnapshot {
    FixtureUIPreferencesStoreSnapshot(
      preferences: preferences,
      loadCount: loadCount,
      saveCount: saveCount,
      restoreCount: restoreCount
    )
  }
}

private struct FixtureApplicationCatalogSnapshot: Sendable {
  let prewarmCount: Int
  let invalidateCount: Int
  let searches: [FixtureApplicationCatalog.Search]
}

private actor FixtureApplicationCatalog: InstalledApplicationCataloging {
  struct Search: Equatable, Sendable {
    let query: String
    let limit: Int
  }

  private let fixedApplications: [ApplicationDescriptor]
  private var prewarmCount = 0
  private var invalidateCount = 0
  private var searches: [Search] = []
  private var prewarmWaiters: [CheckedContinuation<Void, Never>] = []

  init(applications: [ApplicationDescriptor]) {
    fixedApplications = applications
  }

  func applications(forceRefresh: Bool) async -> [ApplicationDescriptor] {
    fixedApplications
  }

  func search(query: String, limit: Int) async -> [ApplicationDescriptor] {
    searches.append(Search(query: query, limit: limit))
    return Array(fixedApplications.prefix(max(0, limit)))
  }

  func prewarm(forceRefresh: Bool) async -> [ApplicationDescriptor] {
    prewarmCount += 1
    let waiters = prewarmWaiters
    prewarmWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    return fixedApplications
  }

  func invalidate() async {
    invalidateCount += 1
  }

  func waitUntilPrewarmed() async {
    guard prewarmCount == 0 else { return }
    await withCheckedContinuation { continuation in
      prewarmWaiters.append(continuation)
    }
  }

  func snapshot() -> FixtureApplicationCatalogSnapshot {
    FixtureApplicationCatalogSnapshot(
      prewarmCount: prewarmCount,
      invalidateCount: invalidateCount,
      searches: searches
    )
  }
}

private struct FixtureCustomWebsiteIconStoreRequest: Equatable, Sendable {
  let imageData: Data
  let request: WebsiteIconRequest
}

private struct FixtureWebsiteIconProviderSnapshot: Sendable {
  let iconRequests: [WebsiteIconRequest]
  let refreshRequests: [WebsiteIconRequest]
  let onlineFetchingChanges: [Bool]
  let customStoreRequests: [FixtureCustomWebsiteIconStoreRequest]
  let clearAutomaticCacheCount: Int
  let cancelCount: Int
}

/// A deterministic provider with no resource loader, URLSession, or disk
/// cache. Every URL remains inert metadata owned by the fixture.
private actor FixtureWebsiteIconProvider: WebsiteIconManaging {
  private var iconRequests: [WebsiteIconRequest] = []
  private var refreshRequests: [WebsiteIconRequest] = []
  private var onlineFetchingChanges: [Bool] = []
  private var customStoreRequests: [FixtureCustomWebsiteIconStoreRequest] = []
  private var clearAutomaticCacheCount = 0
  private var cancelCount = 0

  func icon(for request: WebsiteIconRequest) async -> WebsiteIconResult {
    iconRequests.append(request)
    return .fallback(.generic)
  }

  func refresh(_ request: WebsiteIconRequest) async -> WebsiteIconResult {
    refreshRequests.append(request)
    return .fallback(.generic)
  }

  func cancelAll() async {
    cancelCount += 1
  }

  func updates() async -> AsyncStream<WebsiteIconUpdate> {
    AsyncStream { continuation in continuation.finish() }
  }

  func setOnlineFetchingEnabled(_ enabled: Bool) async {
    onlineFetchingChanges.append(enabled)
  }

  func isOnlineFetchingEnabled() async -> Bool {
    onlineFetchingChanges.last ?? false
  }

  func clearAutomaticCache() async {
    clearAutomaticCacheCount += 1
  }

  func storeCustomIcon(
    imageData: Data,
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation? {
    customStoreRequests.append(
      FixtureCustomWebsiteIconStoreRequest(imageData: imageData, request: request)
    )
    return nil
  }

  func removeCustomIcon(
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation? {
    nil
  }

  func finalizeCustomIconMutation(_ mutation: CustomWebsiteIconMutation) async {}

  func snapshot() -> FixtureWebsiteIconProviderSnapshot {
    FixtureWebsiteIconProviderSnapshot(
      iconRequests: iconRequests,
      refreshRequests: refreshRequests,
      onlineFetchingChanges: onlineFetchingChanges,
      customStoreRequests: customStoreRequests,
      clearAutomaticCacheCount: clearAutomaticCacheCount,
      cancelCount: cancelCount
    )
  }
}

@MainActor
private final class FixtureWebsiteIconImagePicker: WebsiteIconImagePickerPresenting {
  private let selectedURL: URL?
  private(set) var chooseCount = 0
  private(set) var receivedNilPresentationWindow = false

  init(selectedURL: URL?) {
    self.selectedURL = selectedURL
  }

  func chooseImage(presentationWindow: NSWindow?) async -> URL? {
    chooseCount += 1
    receivedNilPresentationWindow = presentationWindow == nil
    return selectedURL
  }
}

@MainActor
private final class FixturePanelPresenter: LauncherPanelPresenting {
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

private final class FixtureEventSink: LauncherEventSink, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [LauncherEvent] = []

  var events: [LauncherEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func receive(_ event: LauncherEvent) {
    lock.lock()
    storage.append(event)
    lock.unlock()
  }
}

private struct FixtureFailure: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}
