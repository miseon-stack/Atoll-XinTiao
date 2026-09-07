@preconcurrency import Carbon
import Foundation
import ShortcutLauncherCore

let shortcutLauncherCarbonSignature: OSType = 0x534C_4E43  // "SLNC"

func captureShortcutLauncherCarbonDelivery(
  signature: OSType,
  systemID: UInt32,
  capture: (UInt32) -> CarbonHotkeyDelivery?
) -> CarbonHotkeyDelivery? {
  guard signature == shortcutLauncherCarbonSignature else { return nil }
  return capture(systemID)
}

private func shortcutLauncherCarbonEventHandler(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else {
    return OSStatus(eventNotHandledErr)
  }

  var carbonID = EventHotKeyID(signature: 0, id: 0)
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &carbonID
  )

  guard status == noErr else { return status }

  let registrar = Unmanaged<CarbonHotkeyRegistrar>
    .fromOpaque(userData)
    .takeUnretainedValue()

  // Resolve the route at Carbon event-arrival time. A system ID can be kept
  // while its logical destination changes during a two-phase commit, so
  // looking it up only after hopping to MainActor could reinterpret an old
  // event as a new binding.
  guard let delivery = captureShortcutLauncherCarbonDelivery(
    signature: carbonID.signature,
    systemID: carbonID.id,
    capture: registrar.captureDelivery(systemID:)
  ) else {
    // A host process may install several Carbon handlers whose numeric IDs
    // overlap. Foreign signatures and stale/unknown routes must continue down
    // that handler chain instead of being consumed by this module.
    return OSStatus(eventNotHandledErr)
  }
  Task { @MainActor in
    registrar.deliver(delivery)
  }
  return noErr
}

struct CarbonHotkeyDelivery: Equatable, Sendable {
  let systemID: UInt32
  let id: HotkeyID
  let generation: UInt64
  let routeRevision: UInt64
}

/// Thread-safe route snapshots bridge Carbon's C callback to MainActor.
///
/// `capture` freezes the meaning of an event when Carbon reports it. `resolve`
/// validates that meaning immediately before delivery. A graph commit bumps
/// `routeRevision`, and shutdown bumps `generation`, so an event queued across
/// either boundary is discarded instead of being reinterpreted.
final class CarbonHotkeyRouteTable: @unchecked Sendable {
  private struct State {
    var routes: [UInt32: HotkeyID] = [:]
    var generation: UInt64 = 1
    var routeRevision: UInt64 = 1
  }

  private let lock = NSLock()
  private var state = State()

  func install(systemID: UInt32, id: HotkeyID) {
    withLock {
      state.routes[systemID] = id
    }
  }

  func remove(systemID: UInt32) {
    withLock {
      _ = state.routes.removeValue(forKey: systemID)
    }
  }

  func replace(systemID oldSystemID: UInt32, with newSystemID: UInt32, id: HotkeyID) {
    withLock {
      advanceRouteRevision()
      state.routes.removeValue(forKey: oldSystemID)
      state.routes[newSystemID] = id
    }
  }

  func reassign(systemID: UInt32, to id: HotkeyID) {
    withLock {
      advanceRouteRevision()
      state.routes[systemID] = id
    }
  }

  func commit(_ routes: [UInt32: HotkeyID]) {
    withLock {
      advanceRouteRevision()
      state.routes = routes
    }
  }

  func removeAll() {
    withLock {
      advanceRouteRevision()
      state.routes.removeAll()
    }
  }

  func shutdown() {
    withLock {
      advanceGeneration()
      advanceRouteRevision()
      state.routes.removeAll()
    }
  }

  func capture(systemID: UInt32) -> CarbonHotkeyDelivery? {
    withLock {
      guard let id = state.routes[systemID] else { return nil }
      return CarbonHotkeyDelivery(
        systemID: systemID,
        id: id,
        generation: state.generation,
        routeRevision: state.routeRevision
      )
    }
  }

  func resolve(_ delivery: CarbonHotkeyDelivery) -> HotkeyID? {
    withLock {
      guard delivery.generation == state.generation,
        delivery.routeRevision == state.routeRevision,
        state.routes[delivery.systemID] == delivery.id
      else { return nil }
      return delivery.id
    }
  }

  private func advanceGeneration() {
    state.generation &+= 1
    if state.generation == 0 { state.generation = 1 }
  }

  private func advanceRouteRevision() {
    state.routeRevision &+= 1
    if state.routeRevision == 0 { state.routeRevision = 1 }
  }

  private func withLock<Result>(_ body: () -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
  private struct Registration {
    let reference: EventHotKeyRef
    let systemID: UInt32
    let hotkey: HotkeyDefinition
  }

  private var eventHandlerRef: EventHandlerRef?
  private var registrations: [HotkeyID: Registration] = [:]
  nonisolated private let routeTable: CarbonHotkeyRouteTable
  private var nextSystemID: UInt32 = 1
  private var handler: (@MainActor @Sendable (HotkeyID) -> Void)?

  public init() {
    routeTable = CarbonHotkeyRouteTable()
  }

  init(routeTable: CarbonHotkeyRouteTable) {
    self.routeTable = routeTable
  }

  public func setHandler(
    _ handler: @escaping @MainActor @Sendable (HotkeyID) -> Void
  ) {
    self.handler = handler
  }

  public func register(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    try hotkey.validate()
    try installEventHandlerIfNeeded()

    if registrations[id] != nil {
      try await replace(hotkey, id: id)
      return
    }

    let systemID = allocateSystemID()
    let registration = try makeRegistration(hotkey, systemID: systemID)
    registrations[id] = registration
    routeTable.install(systemID: systemID, id: id)
  }

  public func replace(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    try hotkey.validate()
    try installEventHandlerIfNeeded()

    guard let oldRegistration = registrations[id] else {
      try await register(hotkey, id: id)
      return
    }
    guard oldRegistration.hotkey != hotkey else { return }

    let temporarySystemID = allocateSystemID()
    let newRegistration = try makeRegistration(hotkey, systemID: temporarySystemID)

    UnregisterEventHotKey(oldRegistration.reference)
    registrations[id] = newRegistration
    routeTable.replace(
      systemID: oldRegistration.systemID,
      with: temporarySystemID,
      id: id
    )
  }

  public func unregister(id: HotkeyID) async {
    guard let registration = registrations.removeValue(forKey: id) else { return }
    routeTable.remove(systemID: registration.systemID)
    UnregisterEventHotKey(registration.reference)
  }

  public func reassign(
    _ hotkey: HotkeyDefinition,
    from oldID: HotkeyID,
    to newID: HotkeyID
  ) async throws {
    guard registrations[newID] == nil else {
      throw LauncherError.hotkeyConflict(hotkey.displayName)
    }
    guard let registration = registrations.removeValue(forKey: oldID),
      registration.hotkey == hotkey
    else {
      try await register(hotkey, id: newID)
      return
    }
    registrations[newID] = registration
    routeTable.reassign(systemID: registration.systemID, to: newID)
  }

  public func commitPreparedRegistrations(
    assignments: [HotkeyID: HotkeyID],
    desiredHotkeys: [HotkeyID: HotkeyDefinition]
  ) async throws {
    guard Set(assignments.values).count == assignments.count,
      Set(assignments.values) == Set(desiredHotkeys.keys)
    else {
      throw LauncherError.invalidConfiguration("快捷键注册切换计划无效")
    }

    var nextRegistrations: [HotkeyID: Registration] = [:]
    for (sourceID, destinationID) in assignments {
      guard let registration = registrations[sourceID],
        registration.hotkey == desiredHotkeys[destinationID]
      else {
        throw LauncherError.invalidConfiguration("快捷键注册切换计划已过期")
      }
      nextRegistrations[destinationID] = registration
    }

    let retainedSystemIDs = Set(nextRegistrations.values.map(\.systemID))
    for registration in registrations.values
    where !retainedSystemIDs.contains(registration.systemID) {
      UnregisterEventHotKey(registration.reference)
    }

    registrations = nextRegistrations
    routeTable.commit(Dictionary(uniqueKeysWithValues: nextRegistrations.map { id, registration in
      (registration.systemID, id)
    }))
  }

  public func unregisterAll() async {
    routeTable.removeAll()
    for registration in registrations.values {
      UnregisterEventHotKey(registration.reference)
    }
    registrations.removeAll()
  }

  public func shutdown() async {
    routeTable.shutdown()
    for registration in registrations.values {
      UnregisterEventHotKey(registration.reference)
    }
    registrations.removeAll()
    handler = nil
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
  }

  nonisolated func captureDelivery(systemID: UInt32) -> CarbonHotkeyDelivery? {
    routeTable.capture(systemID: systemID)
  }

  func deliver(_ delivery: CarbonHotkeyDelivery) {
    guard let id = routeTable.resolve(delivery) else { return }
    handler?(id)
  }

  private func installEventHandlerIfNeeded() throws {
    guard eventHandlerRef == nil else { return }

    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      shortcutLauncherCarbonEventHandler,
      1,
      &eventSpec,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef
    )

    guard status == noErr else {
      throw LauncherError.hotkeyRegistrationFailed(status: status)
    }
  }

  private func carbonModifiers(from modifiers: ModifierSet) -> UInt32 {
    var value: UInt32 = 0
    if modifiers.contains(.command) { value |= UInt32(cmdKey) }
    if modifiers.contains(.option) { value |= UInt32(optionKey) }
    if modifiers.contains(.control) { value |= UInt32(controlKey) }
    if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
    return value
  }

  private func makeRegistration(
    _ hotkey: HotkeyDefinition,
    systemID: UInt32
  ) throws -> Registration {
    var reference: EventHotKeyRef?
    let carbonID = EventHotKeyID(signature: shortcutLauncherCarbonSignature, id: systemID)
    let status = RegisterEventHotKey(
      UInt32(hotkey.keyCode),
      carbonModifiers(from: hotkey.modifiers),
      carbonID,
      GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive),
      &reference
    )

    guard status == noErr, let reference else {
      throw LauncherError.hotkeyRegistrationFailed(status: status)
    }
    return Registration(reference: reference, systemID: systemID, hotkey: hotkey)
  }

  private func allocateSystemID() -> UInt32 {
    let id = nextSystemID
    nextSystemID &+= 1
    if nextSystemID == 0 { nextSystemID = 1 }
    return id
  }
}
