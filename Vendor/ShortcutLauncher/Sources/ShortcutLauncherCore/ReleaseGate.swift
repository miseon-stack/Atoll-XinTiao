import Foundation

public struct ReleaseGate: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case idle
    case waitingForRelease(keyCode: UInt16)
    case armed
  }

  public private(set) var state: State = .idle
  /// The supported modifiers that were held when the invocation hotkey fired.
  ///
  /// Only these modifiers participate in the release gate. A modifier pressed
  /// after presentation must not delay the panel becoming ready.
  public private(set) var invocationModifiers: ModifierSet = []
  /// Invocation modifiers that are still held according to the latest flags
  /// event. This is empty outside the waiting state.
  public private(set) var remainingInvocationModifiers: ModifierSet = []

  private var invocationKeyIsDown = false

  public init() {}

  public var isArmed: Bool {
    state == .armed
  }

  public mutating func begin(invocationKeyCode: UInt16) {
    begin(invocationKeyCode: invocationKeyCode, modifiers: [])
  }

  /// Begins a release gate for a global-hotkey invocation.
  ///
  /// The gate arms only after both the primary key and every supported modifier
  /// held at invocation have been released. Unsupported flag bits are ignored,
  /// keeping this Core type independent from AppKit's event flags.
  public mutating func begin(invocationKeyCode: UInt16, modifiers: ModifierSet) {
    state = .waitingForRelease(keyCode: invocationKeyCode)
    invocationModifiers = modifiers.intersection(.supported)
    remainingInvocationModifiers = invocationModifiers
    invocationKeyIsDown = true
  }

  public mutating func armImmediately() {
    state = .armed
    clearInvocationState()
  }

  @discardableResult
  public mutating func handleKeyDown(keyCode: UInt16) -> Bool {
    guard case .waitingForRelease(let invocationKeyCode) = state else {
      return false
    }
    // Repeated key-down events are deliberately idempotent. The invocation key
    // was already marked down by begin(), and a repeat must never arm the gate.
    guard keyCode == invocationKeyCode else { return false }
    invocationKeyIsDown = true
    return true
  }

  /// Returns true only when this event transitions the gate to `armed`.
  @discardableResult
  public mutating func handleKeyUp(keyCode: UInt16) -> Bool {
    guard case .waitingForRelease(let invocationKeyCode) = state,
      keyCode == invocationKeyCode
    else {
      return false
    }

    invocationKeyIsDown = false
    return armIfReleased()
  }

  /// Updates the currently held modifiers after a platform flags-change event.
  ///
  /// The caller should translate platform flags to `ModifierSet` before calling
  /// this method. The return value has the same meaning as `handleKeyUp`: true
  /// means this event completed the release sequence and armed the gate.
  @discardableResult
  public mutating func handleFlagsChanged(currentModifiers: ModifierSet) -> Bool {
    guard case .waitingForRelease = state else { return false }
    remainingInvocationModifiers = currentModifiers.intersection(invocationModifiers)
    return armIfReleased()
  }

  /// Reconciles the gate with a point-in-time keyboard snapshot.
  ///
  /// The global-hotkey callback and the panel's local event monitor are owned by
  /// different event streams. A very fast tap can release before the panel starts
  /// receiving local key-up/flags events; this snapshot closes that hand-off gap.
  @discardableResult
  public mutating func synchronize(
    invocationKeyIsDown: Bool,
    currentModifiers: ModifierSet
  ) -> Bool {
    guard case .waitingForRelease = state else { return false }
    self.invocationKeyIsDown = invocationKeyIsDown
    remainingInvocationModifiers = currentModifiers.intersection(invocationModifiers)
    return armIfReleased()
  }

  public mutating func reset() {
    state = .idle
    clearInvocationState()
  }

  private mutating func armIfReleased() -> Bool {
    guard case .waitingForRelease = state,
      !invocationKeyIsDown,
      remainingInvocationModifiers.isEmpty
    else {
      return false
    }

    state = .armed
    clearInvocationState()
    return true
  }

  private mutating func clearInvocationState() {
    invocationModifiers = []
    remainingInvocationModifiers = []
    invocationKeyIsDown = false
  }
}
