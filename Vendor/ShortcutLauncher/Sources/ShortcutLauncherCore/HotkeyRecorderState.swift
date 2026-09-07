import Foundation

/// Stable, presentation-independent reasons why a locally recorded shortcut is rejected.
///
/// System-wide availability is deliberately not represented here. That can only be
/// established by the registrar when the user explicitly saves the surrounding edit.
public enum RecorderValidationCode: String, Codable, Equatable, Sendable {
  case unsupportedMainKey
  case missingModifier
  case shiftOnly
  case unsupportedModifier

  public var message: String {
    switch self {
    case .unsupportedMainKey:
      "主键只支持面板中的 38 个字母、数字及符号键"
    case .missingModifier:
      "快捷键至少需要 Command、Option 或 Control 中的一个修饰键"
    case .shiftOnly:
      "不允许只使用 Shift 作为修饰键"
    case .unsupportedModifier:
      "组合中包含不支持的修饰键"
    }
  }
}

/// Visual/input phase of a shortcut recorder.
public enum HotkeyRecorderPhase: Equatable, Sendable {
  case idle
  case focused
  case recording(modifiers: ModifierSet)
  case candidate(HotkeyDefinition)
  case invalid(code: RecorderValidationCode)
}

/// Complete transient state for the local shortcut recorder.
///
/// None of this state is persisted in `LauncherConfiguration`; schema v3 remains unchanged.
public struct HotkeyRecorderState: Equatable, Sendable {
  /// The value captured when the recorder most recently received focus.
  public var original: HotkeyDefinition?

  /// The current edit-session value. A candidate is still only a draft until its owner saves.
  public var selection: HotkeyDefinition?

  public var phase: HotkeyRecorderPhase

  /// Remains true after the recorder relinquishes focus so the surrounding UI
  /// can keep identifying a newly captured combination as unverified until the
  /// owner either saves it or replaces the external value.
  public var candidateRequiresSystemValidation: Bool

  /// Restores the pending marker when Esc cancels a second recording attempt.
  var candidateRequirementCapturedAtFocus: Bool

  /// Tracks one physical key press so key-up and auto-repeat cannot create another candidate.
  public var pressedKeyCode: UInt16?

  public init(
    original: HotkeyDefinition? = nil,
    selection: HotkeyDefinition? = nil,
    phase: HotkeyRecorderPhase = .idle,
    pressedKeyCode: UInt16? = nil,
    candidateRequiresSystemValidation: Bool = false
  ) {
    self.original = original
    self.selection = selection ?? original
    self.phase = phase
    self.pressedKeyCode = pressedKeyCode
    self.candidateRequiresSystemValidation = candidateRequiresSystemValidation
    candidateRequirementCapturedAtFocus = candidateRequiresSystemValidation
  }

  public init(value: HotkeyDefinition?) {
    self.init(original: value, selection: value)
  }

  public var isFocused: Bool {
    if case .idle = phase { return false }
    return true
  }
}

/// Platform-neutral events accepted by `HotkeyRecorderReducer`.
public enum HotkeyRecorderEvent: Equatable, Sendable {
  case focus
  case blur
  case flagsChanged(ModifierSet)
  case keyDown(keyCode: UInt16, modifiers: ModifierSet, isRepeat: Bool)
  case keyUp(keyCode: UInt16)
  case cancel
  case clear
}

/// A reducer result tells the UI whether the surrounding edit-session value must change.
public enum HotkeyRecorderResult: Equatable, Sendable {
  case unchanged
  case candidate(HotkeyDefinition)
  case cancelled(restored: HotkeyDefinition?)
  case cleared
  case rejected(RecorderValidationCode)
}

/// Pure shortcut recording reducer. It performs no Carbon registration, persistence, or I/O.
public enum HotkeyRecorderReducer {
  private static let deleteKeyCodes: Set<UInt16> = [51, 117]

  @discardableResult
  public static func reduce(
    state: inout HotkeyRecorderState,
    event: HotkeyRecorderEvent
  ) -> HotkeyRecorderResult {
    switch event {
    case .focus:
      state.original = state.selection
      state.candidateRequirementCapturedAtFocus = state.candidateRequiresSystemValidation
      state.pressedKeyCode = nil
      state.phase = .focused
      return .unchanged

    case .blur:
      state.pressedKeyCode = nil
      state.phase = .idle
      return .unchanged

    case .flagsChanged(let modifiers):
      guard state.isFocused else { return .unchanged }
      // Once a candidate is formed it remains visible while the user releases its keys.
      // A subsequent keyDown can still replace it without another click.
      if case .candidate = state.phase { return .unchanged }
      state.phase = .recording(modifiers: modifiers)
      return .unchanged

    case .keyDown(let keyCode, let modifiers, let isRepeat):
      guard state.isFocused, !isRepeat, state.pressedKeyCode == nil else {
        return .unchanged
      }

      if keyCode == PhysicalKeyCode.escape {
        return cancel(state: &state)
      }
      if deleteKeyCodes.contains(keyCode) {
        return clear(state: &state)
      }

      state.pressedKeyCode = keyCode
      if let code = validationCode(keyCode: keyCode, modifiers: modifiers) {
        state.phase = .invalid(code: code)
        return .rejected(code)
      }

      let candidate = HotkeyDefinition(keyCode: keyCode, modifiers: modifiers)
      state.selection = candidate
      state.candidateRequiresSystemValidation = true
      state.phase = .candidate(candidate)
      return .candidate(candidate)

    case .keyUp(let keyCode):
      if state.pressedKeyCode == keyCode {
        state.pressedKeyCode = nil
      }
      return .unchanged

    case .cancel:
      guard state.isFocused else { return .unchanged }
      return cancel(state: &state)

    case .clear:
      guard state.isFocused else { return .unchanged }
      return clear(state: &state)
    }
  }

  public static func validationCode(
    keyCode: UInt16,
    modifiers: ModifierSet
  ) -> RecorderValidationCode? {
    guard KeySlotCatalog.allowedKeyCodes.contains(keyCode) else {
      return .unsupportedMainKey
    }
    if modifiers.isEmpty {
      return .missingModifier
    }
    if modifiers == .shift {
      return .shiftOnly
    }
    let primaryModifiers: ModifierSet = [.command, .option, .control]
    if modifiers.intersection(primaryModifiers).isEmpty {
      return .missingModifier
    }
    if !modifiers.subtracting(.supported).isEmpty {
      return .unsupportedModifier
    }
    return nil
  }

  private static func cancel(
    state: inout HotkeyRecorderState
  ) -> HotkeyRecorderResult {
    let restored = state.original
    state.selection = restored
    state.candidateRequiresSystemValidation = state.candidateRequirementCapturedAtFocus
    state.pressedKeyCode = nil
    state.phase = .focused
    return .cancelled(restored: restored)
  }

  private static func clear(
    state: inout HotkeyRecorderState
  ) -> HotkeyRecorderResult {
    state.selection = nil
    state.candidateRequiresSystemValidation = false
    state.pressedKeyCode = nil
    state.phase = .focused
    return .cleared
  }
}
