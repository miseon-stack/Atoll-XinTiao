import Foundation

/// The single source of truth for how one launcher slot is presented at runtime.
///
/// Runtime-only facts such as registration conflicts and target health are kept
/// out of `LauncherConfiguration`, so introducing this type does not change the
/// persisted schema.
public enum BindingRuntimeState: Sendable, Equatable {
  case unbound
  case panelOnly
  case pending(candidate: HotkeyDefinition?)
  case enabled(HotkeyDefinition)
  case paused(HotkeyDefinition)
  case conflicted(HotkeyDefinition)
  case targetUnavailable(hotkey: HotkeyDefinition?)
}

/// A privacy-conscious, immutable view of the registrar's actual state.
///
/// It intentionally contains stable binding identities instead of Carbon
/// handles or OSStatus values.
public struct RegistrationLedgerSnapshot: Sendable, Equatable {
  public var registeredBindingIDs: Set<BindingID>
  public var conflictedBindingIDs: Set<BindingID>
  public var directHotkeysPaused: Bool

  public init(
    registeredBindingIDs: Set<BindingID> = [],
    conflictedBindingIDs: Set<BindingID> = [],
    directHotkeysPaused: Bool = false
  ) {
    self.registeredBindingIDs = registeredBindingIDs
    self.conflictedBindingIDs = conflictedBindingIDs
    self.directHotkeysPaused = directHotkeysPaused
  }
}

/// All facts consumed by `BindingStateResolver` in one immutable value.
public struct BindingStateInputSnapshot: Sendable, Equatable {
  public var committedConfiguration: LauncherConfiguration
  public var editSession: BindingEditSession?
  public var registrationLedger: RegistrationLedgerSnapshot
  public var unavailableTargetBindingIDs: Set<BindingID>
  public var keyLabels: KeyLabelSnapshot

  public init(
    committedConfiguration: LauncherConfiguration,
    editSession: BindingEditSession? = nil,
    registrationLedger: RegistrationLedgerSnapshot = RegistrationLedgerSnapshot(),
    unavailableTargetBindingIDs: Set<BindingID> = [],
    keyLabels: KeyLabelSnapshot = .fallback()
  ) {
    self.committedConfiguration = committedConfiguration
    self.editSession = editSession
    self.registrationLedger = registrationLedger
    self.unavailableTargetBindingIDs = unavailableTargetBindingIDs
    self.keyLabels = keyLabels
  }
}

/// A UI- and host-ready projection of one physical launcher slot.
///
/// `id` is the physical slot rather than an optional `BindingID`, which keeps
/// unbound slots uniquely identifiable in collections.
public struct BindingPresentation: Sendable, Equatable, Identifiable {
  public var id: UInt16 { slotKeyCode }
  public var bindingID: BindingID?
  public var slotKeyCode: UInt16
  public var targetKind: LaunchTargetKind?
  public var displayName: String?
  public var panelKeyLabel: String
  public var directHotkeyLabel: String?
  public var runtimeState: BindingRuntimeState

  public init(
    bindingID: BindingID?,
    slotKeyCode: UInt16,
    targetKind: LaunchTargetKind?,
    displayName: String?,
    panelKeyLabel: String,
    directHotkeyLabel: String?,
    runtimeState: BindingRuntimeState
  ) {
    self.bindingID = bindingID
    self.slotKeyCode = slotKeyCode
    self.targetKind = targetKind
    self.displayName = displayName
    self.panelKeyLabel = panelKeyLabel
    self.directHotkeyLabel = directHotkeyLabel
    self.runtimeState = runtimeState
  }
}

/// Resolves persisted, draft, registrar and target-health facts with the fixed
/// priority: unavailable > pending > conflicted > paused > enabled > panel-only
/// > unbound.
public enum BindingStateResolver {
  public static func resolveAll(
    from input: BindingStateInputSnapshot
  ) -> [BindingPresentation] {
    KeySlotCatalog.all.map { resolve(slotKeyCode: $0.keyCode, from: input) }
  }

  public static func resolve(
    slotKeyCode: UInt16,
    from input: BindingStateInputSnapshot
  ) -> BindingPresentation {
    let committedRecord = input.committedConfiguration.bindings[slotKeyCode]
    let draftRecord = input.editSession?.draft.bindings[slotKeyCode]
    let isPending = input.editSession.map { session in
      let bindingChanged = session.draft.bindings[slotKeyCode] != committedRecord
      let directModeChanged =
        (draftRecord ?? committedRecord)?.directHotkey != nil
        && session.draft.directModeEnabled
          != input.committedConfiguration.directModeEnabled
      return bindingChanged || directModeChanged
    } ?? false

    // A pending deletion still shows the committed target so the UI can explain
    // what will be removed. Other pending edits show the candidate target.
    let presentationRecord = isPending ? (draftRecord ?? committedRecord) : committedRecord
    let bindingID = draftRecord?.id ?? committedRecord?.id
    let state = resolveState(
      committedRecord: committedRecord,
      draftRecord: draftRecord,
      isPending: isPending,
      input: input
    )
    let hotkey = hotkey(from: state)

    return BindingPresentation(
      bindingID: bindingID,
      slotKeyCode: slotKeyCode,
      targetKind: presentationRecord?.target.kind,
      displayName: presentationRecord?.target.displayName,
      panelKeyLabel: keyLabel(for: slotKeyCode, in: input.keyLabels),
      directHotkeyLabel: hotkey.map {
        $0.modifiers.displayName + keyLabel(for: $0.keyCode, in: input.keyLabels)
      },
      runtimeState: state
    )
  }

  private static func resolveState(
    committedRecord: BindingRecord?,
    draftRecord: BindingRecord?,
    isPending: Bool,
    input: BindingStateInputSnapshot
  ) -> BindingRuntimeState {
    let candidateRecord = isPending ? draftRecord : committedRecord
    let relevantBindingIDs = Set(
      [committedRecord?.id, draftRecord?.id].compactMap { $0 }
    )

    if !relevantBindingIDs.isDisjoint(
      with: input.unavailableTargetBindingIDs
    ) {
      return .targetUnavailable(
        hotkey: candidateRecord?.directHotkey ?? committedRecord?.directHotkey
      )
    }

    if isPending {
      return .pending(candidate: draftRecord?.directHotkey)
    }

    guard let record = committedRecord else { return .unbound }
    guard let hotkey = record.directHotkey else { return .panelOnly }

    if input.registrationLedger.conflictedBindingIDs.contains(record.id) {
      return .conflicted(hotkey)
    }

    if !input.committedConfiguration.directModeEnabled
      || input.registrationLedger.directHotkeysPaused
    {
      return .paused(hotkey)
    }

    if input.registrationLedger.registeredBindingIDs.contains(record.id) {
      return .enabled(hotkey)
    }

    // An expected direct shortcut absent from the actual registrar ledger is a
    // runtime conflict even if the platform adapter did not retain a raw error.
    return .conflicted(hotkey)
  }

  private static func hotkey(from state: BindingRuntimeState) -> HotkeyDefinition? {
    switch state {
    case .pending(let candidate): candidate
    case .enabled(let hotkey), .paused(let hotkey), .conflicted(let hotkey): hotkey
    case .targetUnavailable(let hotkey): hotkey
    case .unbound, .panelOnly: nil
    }
  }

  private static func keyLabel(
    for keyCode: UInt16,
    in snapshot: KeyLabelSnapshot
  ) -> String {
    let label = snapshot.label(for: keyCode).trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return label.isEmpty ? KeySlotCatalog.label(for: keyCode) : label
  }
}
