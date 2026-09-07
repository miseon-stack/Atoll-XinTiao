import Foundation

/// The isolated edit scope used by the normal one-slot binding flow.
///
/// The transaction intentionally contains no runtime registration state. Its
/// draft is merged into a full configuration only when the user chooses an
/// explicit commit action.
public struct SingleBindingEditTransaction: Sendable, Equatable {
  public let sessionID: UUID
  public let slotKeyCode: UInt16
  public let original: BindingRecord?
  public var draft: BindingRecord?
  public var shouldEnableAllDirectHotkeysOnCommit: Bool

  public init(
    slotKeyCode: UInt16,
    original: BindingRecord?,
    sessionID: UUID = UUID()
  ) {
    self.sessionID = sessionID
    self.slotKeyCode = slotKeyCode
    self.original = original
    draft = original
    shouldEnableAllDirectHotkeysOnCommit = false
  }

  public var hasChanges: Bool {
    draft != original || shouldEnableAllDirectHotkeysOnCommit
  }

  public mutating func setTarget(_ target: LaunchTarget) {
    if var draft {
      draft.target = target
      draft.physicalKeyCode = slotKeyCode
      self.draft = draft
    } else {
      draft = BindingRecord(physicalKeyCode: slotKeyCode, target: target)
    }
  }

  public mutating func setDirectHotkey(_ hotkey: HotkeyDefinition?) {
    guard var draft else { return }
    draft.directHotkey = hotkey
    self.draft = draft
    if hotkey != nil { shouldEnableAllDirectHotkeysOnCommit = true }
  }

  public mutating func removeBinding() {
    draft = nil
  }

  public func merging(into configuration: LauncherConfiguration) -> LauncherConfiguration {
    var candidate = configuration
    if var draft {
      draft.physicalKeyCode = slotKeyCode
      candidate.bindings[slotKeyCode] = draft
    } else {
      candidate.bindings.removeValue(forKey: slotKeyCode)
    }
    if shouldEnableAllDirectHotkeysOnCommit, draft?.directHotkey != nil {
      candidate.directModeEnabled = true
    }
    return candidate
  }
}
