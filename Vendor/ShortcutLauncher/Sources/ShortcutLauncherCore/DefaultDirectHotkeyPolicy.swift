import Foundation

/// Generates predictable direct shortcuts from a keyboard-grid slot.
///
/// This policy is intentionally separate from `ModifierSet.defaultDirect`.
/// The latter is part of the persisted legacy-migration contract and must
/// remain Command + Option, while new quick bindings default to Control.
public enum DefaultDirectHotkeyPolicy {
  public static let recommendedModifiers: ModifierSet = .control

  public static func hotkey(forSlot keyCode: UInt16) throws -> HotkeyDefinition {
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else {
      throw LauncherError.invalidHotkey("绑定槽位不在支持的 38 键范围内")
    }

    return HotkeyDefinition(keyCode: keyCode, modifiers: recommendedModifiers)
  }

  /// Ordered alternatives for conflict recovery. These are suggestions only;
  /// availability still has to be verified by the platform registrar.
  public static func candidates(forSlot keyCode: UInt16) throws -> [HotkeyDefinition] {
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else {
      throw LauncherError.invalidHotkey("绑定槽位不在支持的 38 键范围内")
    }

    let modifierCandidates: [ModifierSet] = [
      .control,
      .option,
      [.command, .option],
      [.control, .option],
      [.control, .shift],
    ]
    var seen = Set<HotkeyDefinition>()
    return modifierCandidates.compactMap { modifiers in
      let hotkey = HotkeyDefinition(keyCode: keyCode, modifiers: modifiers)
      return seen.insert(hotkey).inserted ? hotkey : nil
    }
  }
}
