import Foundation

@MainActor
public protocol HotkeyRegistering: AnyObject {
  func setHandler(_ handler: @escaping @MainActor @Sendable (HotkeyID) -> Void)
  func register(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws
  func replace(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws
  func reassign(_ hotkey: HotkeyDefinition, from oldID: HotkeyID, to newID: HotkeyID) async throws
  /// Atomically adopts already-registered sources as the complete desired
  /// logical graph. `assignments` maps each current registration ID (including
  /// temporary staging IDs) to its final logical ID.
  ///
  /// Implementations should validate the whole plan before changing routes.
  /// The default is a compatibility fallback that rebuilds from
  /// `desiredHotkeys`; production registrars can preserve the underlying OS
  /// registrations and switch only their routing table.
  func commitPreparedRegistrations(
    assignments: [HotkeyID: HotkeyID],
    desiredHotkeys: [HotkeyID: HotkeyDefinition]
  ) async throws
  func unregister(id: HotkeyID) async
  func unregisterAll() async
  /// Releases registrations and any process-level callback resources owned by
  /// the registrar. Transaction rollbacks should use `unregisterAll()`;
  /// lifecycle teardown should use this method.
  func shutdown() async
}

extension HotkeyRegistering {
  public func reassign(
    _ hotkey: HotkeyDefinition,
    from oldID: HotkeyID,
    to newID: HotkeyID
  ) async throws {
    await unregister(id: oldID)
    do {
      try await register(hotkey, id: newID)
    } catch {
      try? await register(hotkey, id: oldID)
      throw error
    }
  }

  public func shutdown() async {
    await unregisterAll()
  }

  public func commitPreparedRegistrations(
    assignments: [HotkeyID: HotkeyID],
    desiredHotkeys: [HotkeyID: HotkeyDefinition]
  ) async throws {
    await unregisterAll()
    do {
      for (id, hotkey) in desiredHotkeys {
        try await register(hotkey, id: id)
      }
    } catch {
      await unregisterAll()
      throw error
    }
  }
}

@MainActor
public protocol WorkspaceOpening: AnyObject {
  func open(target: LaunchTarget, resolvedURL: URL) async throws
}

public struct ResolvedBookmark: Sendable {
  public var url: URL
  public var isStale: Bool

  public init(url: URL, isStale: Bool) {
    self.url = url
    self.isStale = isStale
  }
}

public protocol BookmarkResolving: Sendable {
  func makeBookmark(for url: URL) throws -> Data
  func resolve(_ bookmarkData: Data) throws -> ResolvedBookmark
}

@MainActor
public protocol ConfigurationStoring: AnyObject {
  var configurationURL: URL { get }
  var backupURL: URL { get }
  var lastLoadRecoveredFromBackup: Bool { get }
  var lastLoadMigrated: Bool { get }
  var lastLoadWasFirstRun: Bool { get }
  func load() throws -> LauncherConfiguration
  func save(_ configuration: LauncherConfiguration) throws
  /// Restores a previously committed value after a later subsystem rejects a
  /// persisted candidate. File-backed stores should also repair their backup.
  func restore(_ configuration: LauncherConfiguration) throws
  func exportData(for configuration: LauncherConfiguration) throws -> Data
  func decodeImport(_ data: Data) throws -> PreparedConfigurationImport
}

extension ConfigurationStoring {
  /// Source-compatible fallback for older injected stores. Production
  /// file-backed storage overrides this to keep primary and backup aligned.
  public func restore(_ configuration: LauncherConfiguration) throws {
    try save(configuration)
  }
}

public enum BookmarkPolicy: String, Codable, Sendable {
  case securityScopedWhenAvailable
  case lastKnownURLOnly
}

public enum LauncherEventName: String, Sendable {
  case moduleStarted
  case configurationMigrated
  case configurationRecovered
  case bindingExecuted
  case bindingExecutionFailed
  case directHotkeyRetry
  case editCommitted
  case importCompleted
}

public struct LauncherEvent: Sendable {
  public var name: LauncherEventName
  public var bindingID: BindingID?
  public var targetKind: LaunchTargetKind?
  public var triggerSource: TriggerSource?
  public var resultCode: String?
  public var durationMilliseconds: UInt64?
  public var configurationRevision: UInt64?

  public init(
    name: LauncherEventName,
    bindingID: BindingID? = nil,
    targetKind: LaunchTargetKind? = nil,
    triggerSource: TriggerSource? = nil,
    resultCode: String? = nil,
    durationMilliseconds: UInt64? = nil,
    configurationRevision: UInt64? = nil
  ) {
    self.name = name
    self.bindingID = bindingID?.hostSafeProjection
    self.targetKind = targetKind
    self.triggerSource = triggerSource
    self.resultCode = resultCode
    self.durationMilliseconds = durationMilliseconds
    self.configurationRevision = configurationRevision
  }
}

public protocol LauncherEventSink: Sendable {
  func receive(_ event: LauncherEvent)
}

public protocol LauncherDiagnosticsSink: Sendable {
  func record(code: String, metadata: [String: String])
}

public struct NoopLauncherEventSink: LauncherEventSink {
  public init() {}
  public func receive(_ event: LauncherEvent) {}
}

public struct NoopLauncherDiagnosticsSink: LauncherDiagnosticsSink {
  public init() {}
  public func record(code: String, metadata: [String: String]) {}
}

public struct ShortcutLauncherHostConfiguration: Sendable {
  public var storageDirectory: URL
  public var bookmarkPolicy: BookmarkPolicy
  public var eventSink: any LauncherEventSink
  public var diagnosticsSink: any LauncherDiagnosticsSink
  public var initialPanelHotkey: HotkeyDefinition?

  public init(
    storageDirectory: URL,
    bookmarkPolicy: BookmarkPolicy = .securityScopedWhenAvailable,
    eventSink: any LauncherEventSink = NoopLauncherEventSink(),
    diagnosticsSink: any LauncherDiagnosticsSink = NoopLauncherDiagnosticsSink(),
    initialPanelHotkey: HotkeyDefinition? = nil
  ) {
    self.storageDirectory = storageDirectory
    self.bookmarkPolicy = bookmarkPolicy
    self.eventSink = eventSink
    self.diagnosticsSink = diagnosticsSink
    self.initialPanelHotkey = initialPanelHotkey
  }
}

@MainActor
public protocol ShortcutLauncherModuleProtocol: AnyObject {
  var currentConfiguration: LauncherConfiguration { get }
  func start() async throws
  func stop() async
  func beginEditing()
  func cancelEditing()
  func commitEditing() async
  func execute(bindingID: BindingID, source: TriggerSource) async
}
