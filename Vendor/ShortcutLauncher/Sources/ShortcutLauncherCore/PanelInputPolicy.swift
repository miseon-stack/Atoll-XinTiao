import Foundation

/// Platform-neutral keyboard input received while the launcher panel is visible.
///
/// AppKit adapters should pass only device-independent shortcut modifiers. This
/// keeps Caps Lock and other keyboard-state flags from changing slot behavior.
public struct PanelInputEvent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case keyDown
    case keyUp
    case flagsChanged
  }

  public let kind: Kind
  public let keyCode: UInt16
  public let modifiers: ModifierSet
  public let isRepeat: Bool

  public init(
    kind: Kind,
    keyCode: UInt16,
    modifiers: ModifierSet = [],
    isRepeat: Bool = false
  ) {
    self.kind = kind
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.isRepeat = isRepeat
  }
}

/// The control that currently owns keyboard input inside the launcher surface.
///
/// Only the panel itself may turn a character key into a slot activation. Every
/// child editing context receives its original event unchanged, including Esc,
/// Return and arrow keys used by an input method or system picker.
public enum PanelInputOwnership: String, CaseIterable, Equatable, Sendable {
  case panel
  case textInput
  case popover
  case sheet
  case settings
  case hotkeyRecorder
  case systemPicker

  public var allowsSlotActivation: Bool { self == .panel }
}

/// A platform-neutral instruction for the panel's local event adapter.
public enum PanelInputDecision: Equatable, Sendable {
  /// Return the original event to AppKit and the current first responder.
  case passThrough
  /// Remove the event without producing a second user action.
  case consume
  /// Dismiss the main panel. Child contexts handle their own Esc before this policy.
  case dismissPanel
  /// Activate or configure the physical slot represented by this key code.
  case activateSlot(UInt16)
}

/// Pure event policy shared by the AppKit adapter and deterministic unit tests.
///
/// The release gate is passed by value ownership (`inout`) so the policy can
/// close the hand-off between the global-hotkey callback and the panel's local
/// event stream without importing AppKit into Core.
public struct PanelInputPolicy: Sendable {
  public let allowedKeyCodes: Set<UInt16>

  public init(allowedKeyCodes: Set<UInt16> = KeySlotCatalog.allowedKeyCodes) {
    self.allowedKeyCodes = allowedKeyCodes
  }

  public func evaluate(
    _ event: PanelInputEvent,
    ownership: PanelInputOwnership,
    releaseGate: inout ReleaseGate
  ) -> PanelInputDecision {
    // Text entry, a popover, a sheet, settings and the recorder must retain full
    // keyboard ownership. Importantly, this check also prevents a child Esc or
    // IME Return from mutating the panel's release gate.
    guard ownership.allowsSlotActivation else { return .passThrough }

    switch event.kind {
    case .flagsChanged:
      guard case .waitingForRelease = releaseGate.state else { return .passThrough }
      releaseGate.handleFlagsChanged(currentModifiers: event.modifiers)
      return .consume

    case .keyUp:
      guard case .waitingForRelease(let invocationKeyCode) = releaseGate.state,
        event.keyCode == invocationKeyCode
      else {
        return .passThrough
      }
      releaseGate.handleKeyUp(keyCode: event.keyCode)
      return .consume

    case .keyDown:
      break
    }

    if case .waitingForRelease(let invocationKeyCode) = releaseGate.state {
      if event.keyCode == invocationKeyCode {
        releaseGate.handleKeyDown(keyCode: event.keyCode)
        return .consume
      }
      // A key pressed before the invocation sequence is fully released must not
      // activate a slot. It remains available to AppKit instead of being eaten.
      return .passThrough
    }

    guard releaseGate.isArmed else { return .passThrough }

    let shortcutModifiers = event.modifiers.intersection(.supported)
    if event.keyCode == PhysicalKeyCode.escape {
      guard shortcutModifiers.isEmpty else { return .passThrough }
      return event.isRepeat ? .consume : .dismissPanel
    }

    // System/application shortcuts and VoiceOver chords retain their normal
    // meaning. Unsupported state bits (for example Caps Lock) are ignored.
    guard shortcutModifiers.isEmpty else { return .passThrough }
    guard allowedKeyCodes.contains(event.keyCode) else { return .passThrough }

    // Repeats are consumed so a held slot key cannot execute or open twice.
    guard !event.isRepeat else { return .consume }
    return .activateSlot(event.keyCode)
  }
}
