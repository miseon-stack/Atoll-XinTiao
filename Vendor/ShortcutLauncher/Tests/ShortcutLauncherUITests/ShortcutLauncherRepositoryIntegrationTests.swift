import Foundation
import XCTest

@testable import ShortcutLauncherCore
@testable import ShortcutLauncherUI

@MainActor
final class ShortcutLauncherRepositoryIntegrationTests: XCTestCase {
  func testRepositoryInitializerPreservesLoadRecoveryMetadata() async throws {
    let configuration = LauncherConfiguration(bindings: [
      0: BindingRecord(
        id: BindingID(rawValue: "repository-loaded"),
        physicalKeyCode: 0,
        target: webTarget("loaded.example")
      )
    ])
    let repository = ModuleRepositorySpy(loadResult: ConfigurationLoadResult(
      configuration: configuration,
      recoveredFromBackup: true
    ))
    let module = makeModule(repository: repository)

    try await module.start()

    XCTAssertEqual(module.currentConfiguration, configuration)
    XCTAssertEqual(module.configurationURL, repository.configurationURL)
    XCTAssertTrue(module.snapshot.issueCodes.contains(.configurationRecovered))
    let loadCallCount = await repository.loadCallCount
    XCTAssertEqual(loadCallCount, 1)
    await module.stop()
  }

  func testFirstRunInitialPanelHotkeyIsSavedThroughRepository() async throws {
    let repository = ModuleRepositorySpy(loadResult: ConfigurationLoadResult(
      configuration: LauncherConfiguration(),
      wasFirstRun: true
    ))
    let initialHotkey = HotkeyDefinition(keyCode: 3, modifiers: [.command, .shift])
    let module = makeModule(repository: repository, initialPanelHotkey: initialHotkey)

    try await module.start()

    XCTAssertEqual(module.currentConfiguration.panelHotkey, initialHotkey)
    let savedConfigurations = await repository.savedConfigurations
    XCTAssertEqual(savedConfigurations, [module.currentConfiguration])
    await module.stop()
  }

  func testSuspendedRepositoryLoadDoesNotBlockMainActor() async throws {
    let repository = ModuleRepositorySpy(
      loadResult: ConfigurationLoadResult(configuration: LauncherConfiguration()),
      suspendsFirstLoad: true
    )
    let module = makeModule(repository: repository)
    let startTask = Task { @MainActor in
      try await module.start()
    }

    await repository.waitUntilLoadStarts()

    XCTAssertEqual(module.snapshot.lifecycleState, .starting)
    XCTAssertEqual(module.statusText, "尚未启动")
    await repository.resumeFirstLoad()
    try await startTask.value
    XCTAssertEqual(module.snapshot.lifecycleState, .running)
    await module.stop()
  }

  func testConcreteRepositoryPersistsModuleCommitUsingSchemaV3() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(storageDirectory: directory)
    let module = makeModule(repository: repository)

    try await module.start()
    module.requestBinding(for: 0)
    module.bindWebURL("https://persisted.example", to: 0)
    _ = await module.commitEditingWithResult()

    let persisted = try await repository.load()
    XCTAssertEqual(persisted.configuration, module.currentConfiguration)
    XCTAssertEqual(persisted.configuration.schemaVersion, 3)
    XCTAssertEqual(persisted.configuration.bindings[0]?.target.displayName, "persisted.example")
    await module.stop()
  }

  func testSynchronousStoreInitializerRemainsSourceCompatible() async throws {
    let store = ModuleCompatibilityStore()
    let module = ShortcutLauncherModule(
      registrar: ModuleRepositoryFakeRegistrar(),
      store: store,
      bookmarkResolver: ModuleRepositoryBookmarkResolver(),
      opener: ModuleRepositoryFakeOpener()
    )

    try await module.start()
    module.requestBinding(for: 0)
    module.bindWebURL("https://compatible.example", to: 0)
    _ = await module.commitEditingWithResult()

    XCTAssertEqual(store.loadCount, 1)
    XCTAssertEqual(store.saveCount, 1)
    XCTAssertEqual(store.configuration, module.currentConfiguration)
    await module.stop()
  }

  private func makeModule(
    repository: any ConfigurationRepositoryProtocol,
    initialPanelHotkey: HotkeyDefinition? = nil
  ) -> ShortcutLauncherModule {
    ShortcutLauncherModule(
      registrar: ModuleRepositoryFakeRegistrar(),
      repository: repository,
      bookmarkResolver: ModuleRepositoryBookmarkResolver(),
      opener: ModuleRepositoryFakeOpener(),
      initialPanelHotkey: initialPanelHotkey,
      ownerLease: HotkeyOwnerLease()
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "shortcut-launcher-module-repository-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func webTarget(_ host: String) -> LaunchTarget {
    LaunchTarget(
      kind: .web,
      displayName: host,
      lastKnownURL: URL(string: "https://\(host)")!
    )
  }
}

private actor ModuleRepositorySpy: ConfigurationRepositoryProtocol {
  nonisolated let configurationURL = URL(
    fileURLWithPath: "/tmp/shortcut-launcher-module-repository-spy.json"
  )
  nonisolated let backupURL = URL(
    fileURLWithPath: "/tmp/shortcut-launcher-module-repository-spy.backup.json"
  )

  private let loadResult: ConfigurationLoadResult
  private let suspendsFirstLoad: Bool
  private var didSuspendLoad = false
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private var loadStartWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var loadCallCount = 0
  private(set) var savedConfigurations: [LauncherConfiguration] = []

  init(loadResult: ConfigurationLoadResult, suspendsFirstLoad: Bool = false) {
    self.loadResult = loadResult
    self.suspendsFirstLoad = suspendsFirstLoad
  }

  func load() async throws -> ConfigurationLoadResult {
    loadCallCount += 1
    let waiters = loadStartWaiters
    loadStartWaiters.removeAll()
    for waiter in waiters { waiter.resume() }

    if suspendsFirstLoad, !didSuspendLoad {
      didSuspendLoad = true
      await withCheckedContinuation { continuation in
        loadContinuation = continuation
      }
    }
    return loadResult
  }

  func save(_ configuration: LauncherConfiguration) async throws {
    savedConfigurations.append(configuration)
  }

  func exportData(for configuration: LauncherConfiguration) async throws -> Data {
    try JSONEncoder().encode(configuration)
  }

  func prepareImport(_ data: Data) async throws -> PreparedConfigurationImport {
    PreparedConfigurationImport(
      configuration: try JSONDecoder().decode(LauncherConfiguration.self, from: data)
    )
  }

  func waitUntilLoadStarts() async {
    guard loadCallCount == 0 else { return }
    await withCheckedContinuation { continuation in
      loadStartWaiters.append(continuation)
    }
  }

  func resumeFirstLoad() {
    loadContinuation?.resume()
    loadContinuation = nil
  }
}

@MainActor
private final class ModuleCompatibilityStore: ConfigurationStoring {
  let configurationURL = URL(
    fileURLWithPath: "/tmp/shortcut-launcher-module-compatibility.json"
  )
  var configuration = LauncherConfiguration()
  private(set) var loadCount = 0
  private(set) var saveCount = 0

  func load() throws -> LauncherConfiguration {
    loadCount += 1
    return configuration
  }

  func save(_ configuration: LauncherConfiguration) throws {
    saveCount += 1
    self.configuration = configuration
  }
}

@MainActor
private final class ModuleRepositoryFakeRegistrar: HotkeyRegistering {
  private var registrations: [HotkeyID: HotkeyDefinition] = [:]
  private var handler: (@MainActor @Sendable (HotkeyID) -> Void)?

  func setHandler(_ handler: @escaping @MainActor @Sendable (HotkeyID) -> Void) {
    self.handler = handler
  }

  func register(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    registrations[id] = hotkey
  }

  func replace(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    registrations[id] = hotkey
  }

  func unregister(id: HotkeyID) async {
    registrations.removeValue(forKey: id)
  }

  func unregisterAll() async {
    registrations.removeAll()
  }
}

private struct ModuleRepositoryBookmarkResolver: BookmarkResolving {
  func makeBookmark(for url: URL) throws -> Data {
    Data(url.absoluteString.utf8)
  }

  func resolve(_ bookmarkData: Data) throws -> ResolvedBookmark {
    let rawValue = String(decoding: bookmarkData, as: UTF8.self)
    return ResolvedBookmark(
      url: URL(string: rawValue) ?? URL(fileURLWithPath: "/tmp"),
      isStale: false
    )
  }
}

@MainActor
private final class ModuleRepositoryFakeOpener: WorkspaceOpening {
  func open(target: LaunchTarget, resolvedURL: URL) async throws {}
}
