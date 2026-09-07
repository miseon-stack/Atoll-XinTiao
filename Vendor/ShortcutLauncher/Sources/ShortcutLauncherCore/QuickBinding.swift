import Foundation

/// The shortcut behavior requested by the quick-binding surface.
///
/// This is transient intent and is deliberately not encoded into schema v3.
public enum QuickBindingShortcutChoice: Sendable, Equatable {
  /// Assign the Phase 4 recommendation: Control + the selected slot key.
  case defaultForNew
  /// Keep the slot's existing direct shortcut exactly as it is, including nil.
  case preserveExisting
  /// Keep the binding available from the panel without a global shortcut.
  case panelOnly
  /// Use the selected modifiers with the slot key as the immutable primary key.
  case customModifiers(ModifierSet)
}

/// A complete, one-slot binding request suitable for atomic commit.
public struct QuickBindingIntent: Sendable, Equatable {
  public let slotKeyCode: UInt16
  public let target: LaunchTarget
  public let shortcutChoice: QuickBindingShortcutChoice

  public init(
    slotKeyCode: UInt16,
    target: LaunchTarget,
    shortcutChoice: QuickBindingShortcutChoice
  ) {
    self.slotKeyCode = slotKeyCode
    self.target = target
    self.shortcutChoice = shortcutChoice
  }
}

/// Pure candidate construction for the quick-binding flow.
///
/// The builder performs no persistence, Carbon registration, UI mutation or
/// direct-mode policy changes. The caller can feed the returned configuration
/// into the existing staged-registration transaction.
public enum QuickBindingCandidateBuilder {
  public static func makeCandidate(
    from configuration: LauncherConfiguration,
    intent: QuickBindingIntent
  ) throws -> LauncherConfiguration {
    guard KeySlotCatalog.allowedKeyCodes.contains(intent.slotKeyCode) else {
      throw LauncherError.invalidHotkey("绑定槽位不在支持的 38 键范围内")
    }

    let original = configuration.bindings[intent.slotKeyCode]
    let directHotkey: HotkeyDefinition?
    switch intent.shortcutChoice {
    case .defaultForNew:
      directHotkey = try DefaultDirectHotkeyPolicy.hotkey(forSlot: intent.slotKeyCode)
    case .preserveExisting:
      directHotkey = original?.directHotkey
    case .panelOnly:
      directHotkey = nil
    case .customModifiers(let modifiers):
      let hotkey = HotkeyDefinition(keyCode: intent.slotKeyCode, modifiers: modifiers)
      try hotkey.validate()
      directHotkey = hotkey
    }

    var candidate = configuration
    candidate.bindings[intent.slotKeyCode] = BindingRecord(
      id: original?.id ?? .make(),
      physicalKeyCode: intent.slotKeyCode,
      target: intent.target,
      directHotkey: directHotkey
    )
    try ConfigurationValidator.validate(candidate)
    return candidate
  }
}
