import AppKit
import ShortcutLauncherCore
import SwiftUI

/// Window-local AppKit shortcut recorder. It never installs a global event monitor.
@MainActor
public final class LocalHotkeyRecorderNSView: NSView {
  public var onValueChange: ((HotkeyDefinition?) -> Void)?
  public var onStateChange: ((HotkeyRecorderState) -> Void)?
  /// Called before this view is allowed to become first responder. Production
  /// owners use this hook to suspend their Carbon registrations first, so the
  /// very first recorded key cannot be consumed by an existing global hotkey.
  public var onActivationRequest: (@MainActor () async -> Bool)?
  /// Balances a successful activation request after blur or a terminal recorder
  /// action. Owners must make this operation idempotent because view teardown can
  /// race an in-flight activation.
  public var onDeactivation: (@MainActor () async -> Void)?

  public private(set) var recorderState: HotkeyRecorderState
  public var labelSnapshot: KeyLabelSnapshot {
    didSet { updatePresentation() }
  }
  public var recorderEnabled = true {
    didSet {
      if !recorderEnabled { cancelCaptureIntent() }
      updatePresentation()
    }
  }

  private let labelField = NSTextField(labelWithString: "")
  private var activationRequestTask: Task<Void, Never>?
  private var activationRequestRevision: UInt64 = 0
  private var activationAuthorized = false
  private var recordingSessionRequested = false

  public init(
    hotkey: HotkeyDefinition?,
    labelSnapshot: KeyLabelSnapshot = .fallback()
  ) {
    recorderState = HotkeyRecorderState(value: hotkey)
    self.labelSnapshot = labelSnapshot
    super.init(frame: .zero)
    configureView()
    updatePresentation()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override var acceptsFirstResponder: Bool { recorderEnabled }
  public override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
  public override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 44) }

  public override func drawFocusRingMask() {
    NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
  }

  public override func becomeFirstResponder() -> Bool {
    guard recorderEnabled else { return false }
    if onActivationRequest != nil, !activationAuthorized {
      requestCaptureActivationIfNeeded()
      return false
    }
    let accepted = super.becomeFirstResponder()
    if accepted {
      process(.focus)
      needsDisplay = true
    }
    return accepted
  }

  public override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      process(.blur)
      endRequestedRecordingSession()
      needsDisplay = true
    }
    return accepted
  }

  public override func mouseDown(with event: NSEvent) {
    guard recorderEnabled else { return }
    window?.makeFirstResponder(self)
  }

  public override func keyDown(with event: NSEvent) {
    guard recorderEnabled, window?.firstResponder === self else {
      super.keyDown(with: event)
      return
    }
    processKeyDown(event)
  }

  /// Command-modified events are offered to the menu as key equivalents before normal
  /// keyDown dispatch. Consuming them here while focused prevents actions such as Command-Q
  /// from firing instead of being recorded.
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard recorderEnabled, window?.firstResponder === self, event.type == .keyDown else {
      return super.performKeyEquivalent(with: event)
    }
    processKeyDown(event)
    return true
  }

  public override func keyUp(with event: NSEvent) {
    guard recorderEnabled, window?.firstResponder === self else {
      super.keyUp(with: event)
      return
    }
    process(.keyUp(keyCode: event.keyCode))
  }

  public override func flagsChanged(with event: NSEvent) {
    guard recorderEnabled, window?.firstResponder === self else {
      super.flagsChanged(with: event)
      return
    }
    process(.flagsChanged(Self.modifierSet(from: event.modifierFlags)))
  }

  public override func accessibilityPerformPress() -> Bool {
    guard recorderEnabled else { return false }
    if onActivationRequest != nil, !activationAuthorized {
      requestCaptureActivationIfNeeded()
      return true
    }
    return window?.makeFirstResponder(self) ?? false
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      cancelCaptureIntent()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  /// Synchronizes an owner-provided draft without replacing an in-progress local recording.
  public func updateExternalHotkey(_ hotkey: HotkeyDefinition?) {
    guard !recorderState.isFocused, recorderState.selection != hotkey else { return }
    recorderState = HotkeyRecorderState(value: hotkey)
    updatePresentation()
  }

  /// Public event seam for deterministic component tests and accessible fallback input.
  @discardableResult
  public func process(_ event: HotkeyRecorderEvent) -> HotkeyRecorderResult {
    let result = HotkeyRecorderReducer.reduce(state: &recorderState, event: event)
    switch result {
    case .candidate(let hotkey):
      onValueChange?(hotkey)
    case .cancelled(let restored):
      onValueChange?(restored)
    case .cleared:
      onValueChange?(nil)
    case .unchanged, .rejected:
      break
    }
    updatePresentation()
    onStateChange?(recorderState)
    switch result {
    case .candidate, .cancelled, .cleared:
      // One click plus one key press completes a recording attempt. Relinquish
      // focus so the owner's previously committed global graph is restored
      // immediately instead of remaining unavailable for the sheet lifetime.
      if window?.firstResponder === self {
        window?.makeFirstResponder(nil)
      }
    case .unchanged, .rejected:
      break
    }
    return result
  }

  public static func modifierSet(from flags: NSEvent.ModifierFlags) -> ModifierSet {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    var modifiers: ModifierSet = []
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    return modifiers
  }

  private func processKeyDown(_ event: NSEvent) {
    process(
      .keyDown(
        keyCode: event.keyCode,
        modifiers: Self.modifierSet(from: event.modifierFlags),
        isRepeat: event.isARepeat
      )
    )
  }

  private func configureView() {
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1

    labelField.alignment = .center
    labelField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    labelField.lineBreakMode = .byTruncatingTail
    labelField.translatesAutoresizingMaskIntoConstraints = false
    addSubview(labelField)
    NSLayoutConstraint.activate([
      labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("快捷键录制器")
    setAccessibilityHelp("按空格或点击后，再按下包含 Command、Option 或 Control 的组合键；Esc 取消，Delete 清除")
  }

  private func requestCaptureActivationIfNeeded() {
    guard recorderEnabled, activationRequestTask == nil,
      let onActivationRequest
    else { return }

    activationRequestRevision &+= 1
    let revision = activationRequestRevision
    recordingSessionRequested = true
    updatePresentation()

    let onDeactivation = self.onDeactivation
    activationRequestTask = Task { @MainActor [weak self] in
      let isReady = await onActivationRequest()
      guard let self else {
        await onDeactivation?()
        return
      }
      self.activationRequestTask = nil
      guard self.activationRequestRevision == revision,
        self.recordingSessionRequested,
        self.recorderEnabled,
        self.window != nil,
        isReady
      else {
        if self.activationRequestRevision == revision {
          self.recordingSessionRequested = false
          self.updatePresentation()
        }
        await onDeactivation?()
        return
      }
      self.activationAuthorized = true
      let accepted = self.window?.makeFirstResponder(self) == true
      if !accepted {
        self.activationAuthorized = false
        self.recordingSessionRequested = false
        self.updatePresentation()
        await onDeactivation?()
      }
    }
  }

  private func cancelCaptureIntent() {
    activationRequestRevision &+= 1
    activationAuthorized = false

    if window?.firstResponder === self {
      window?.makeFirstResponder(nil)
    } else {
      endRequestedRecordingSession()
    }
  }

  private func endRequestedRecordingSession() {
    activationAuthorized = false
    guard recordingSessionRequested else { return }
    recordingSessionRequested = false
    updatePresentation()
    guard let onDeactivation else { return }
    Task { @MainActor in await onDeactivation() }
  }

  private func updatePresentation() {
    let text: String
    let isError: Bool
    if activationRequestTask != nil {
      text = "正在准备快捷键录制…"
      isError = false
    } else {
      switch recorderState.phase {
    case .idle:
      if let hotkey = recorderState.selection {
        let displayName = labelSnapshot.displayName(for: hotkey)
        text = recorderState.candidateRequiresSystemValidation
          ? "\(displayName) · 待系统验证"
          : displayName
      } else {
        text = "点击后按下快捷键"
      }
      isError = false
    case .focused:
      text = "请按组合键；Esc 取消"
      isError = false
    case .recording(let modifiers):
      text = modifiers.isEmpty ? "请按组合键；Esc 取消" : "\(modifiers.displayName)…"
      isError = false
    case .candidate(let hotkey):
      text = "\(labelSnapshot.displayName(for: hotkey)) · 待系统验证"
      isError = false
    case .invalid(let code):
      text = code.message
      isError = true
      }
    }

    labelField.stringValue = text
    labelField.textColor = recorderEnabled
      ? (isError ? .systemOrange : .labelColor)
      : .disabledControlTextColor
    layer?.backgroundColor = (recorderEnabled
      ? NSColor.controlBackgroundColor
      : NSColor.windowBackgroundColor).cgColor
    layer?.borderColor = (isError
      ? NSColor.systemOrange
      : recorderState.isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    focusRingType = recorderState.isFocused ? .default : .none
    setAccessibilityEnabled(recorderEnabled)
    setAccessibilityValue(text)
    toolTip = text
  }
}

/// SwiftUI wrapper around the first-responder-only AppKit recorder.
public struct HotkeyRecorderView: NSViewRepresentable {
  @Binding private var hotkey: HotkeyDefinition?
  private let labelSnapshot: KeyLabelSnapshot
  private let accessibilityIdentifier: String
  private let focusRequestID: UInt64
  private let onActivationRequest: (@MainActor () async -> Bool)?
  private let onDeactivation: (@MainActor () async -> Void)?
  private let onStateChange: ((HotkeyRecorderState) -> Void)?
  @Environment(\.isEnabled) private var isEnabled

  public init(
    hotkey: Binding<HotkeyDefinition?>,
    labelSnapshot: KeyLabelSnapshot = .fallback(),
    accessibilityIdentifier: String = "hotkey-recorder",
    focusRequestID: UInt64 = 0,
    onActivationRequest: (@MainActor () async -> Bool)? = nil,
    onDeactivation: (@MainActor () async -> Void)? = nil,
    onStateChange: ((HotkeyRecorderState) -> Void)? = nil
  ) {
    _hotkey = hotkey
    self.labelSnapshot = labelSnapshot
    self.accessibilityIdentifier = accessibilityIdentifier
    self.focusRequestID = focusRequestID
    self.onActivationRequest = onActivationRequest
    self.onDeactivation = onDeactivation
    self.onStateChange = onStateChange
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(
      hotkey: $hotkey,
      onActivationRequest: onActivationRequest,
      onDeactivation: onDeactivation,
      onStateChange: onStateChange
    )
  }

  public func makeNSView(context: Context) -> LocalHotkeyRecorderNSView {
    let view = LocalHotkeyRecorderNSView(hotkey: hotkey, labelSnapshot: labelSnapshot)
    view.setAccessibilityIdentifier(accessibilityIdentifier)
    view.onValueChange = { [weak coordinator = context.coordinator] value in
      coordinator?.hotkey.wrappedValue = value
    }
    view.onStateChange = { [weak coordinator = context.coordinator] state in
      coordinator?.onStateChange?(state)
    }
    view.onActivationRequest = { [weak coordinator = context.coordinator] in
      await coordinator?.onActivationRequest?() ?? true
    }
    view.onDeactivation = { [weak coordinator = context.coordinator] in
      await coordinator?.onDeactivation?()
    }
    return view
  }

  public func updateNSView(_ nsView: LocalHotkeyRecorderNSView, context: Context) {
    context.coordinator.hotkey = $hotkey
    context.coordinator.onActivationRequest = onActivationRequest
    context.coordinator.onDeactivation = onDeactivation
    context.coordinator.onStateChange = onStateChange
    nsView.labelSnapshot = labelSnapshot
    nsView.recorderEnabled = isEnabled
    nsView.updateExternalHotkey(hotkey)
    if isEnabled, context.coordinator.lastFocusRequestID != focusRequestID {
      context.coordinator.lastFocusRequestID = focusRequestID
      DispatchQueue.main.async { [weak nsView] in
        guard let nsView, nsView.recorderEnabled else { return }
        nsView.window?.makeFirstResponder(nsView)
      }
    }
  }

  @MainActor
  public final class Coordinator {
    fileprivate var hotkey: Binding<HotkeyDefinition?>
    fileprivate var onActivationRequest: (@MainActor () async -> Bool)?
    fileprivate var onDeactivation: (@MainActor () async -> Void)?
    fileprivate var onStateChange: ((HotkeyRecorderState) -> Void)?
    fileprivate var lastFocusRequestID: UInt64 = 0

    fileprivate init(
      hotkey: Binding<HotkeyDefinition?>,
      onActivationRequest: (@MainActor () async -> Bool)?,
      onDeactivation: (@MainActor () async -> Void)?,
      onStateChange: ((HotkeyRecorderState) -> Void)?
    ) {
      self.hotkey = hotkey
      self.onActivationRequest = onActivationRequest
      self.onDeactivation = onDeactivation
      self.onStateChange = onStateChange
    }
  }
}
