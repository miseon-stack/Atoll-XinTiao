import AppKit
import SwiftUI

/// AppKit-backed search field that preserves IME ownership while exposing
/// command-palette navigation to SwiftUI.
struct ApplicationSearchField: NSViewRepresentable {
  @Binding var text: String
  let prompt: String
  let focusRequestID: UInt64
  let onTextChange: (String) -> Void
  let onMove: (ApplicationSearchNavigationDirection) -> Void
  let onSubmit: (_ hasMarkedText: Bool) -> Void
  let onEscape: (_ hasMarkedText: Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = prompt
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = true
    field.delegate = context.coordinator
    field.setAccessibilityIdentifier("launcher.quick.search")
    field.setAccessibilityLabel("搜索应用或输入网址")
    field.setAccessibilityHelp("使用上下方向键选择结果，按 Return 绑定")
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    guard context.coordinator.lastFocusRequestID != focusRequestID else { return }
    context.coordinator.lastFocusRequestID = focusRequestID
    DispatchQueue.main.async { [weak field] in
      guard let field, let window = field.window else { return }
      window.makeFirstResponder(field)
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: ApplicationSearchField
    var lastFocusRequestID: UInt64?

    init(parent: ApplicationSearchField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      let value = field.stringValue
      if parent.text != value { parent.text = value }
      parent.onTextChange(value)
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      let hasMarkedText = textView.hasMarkedText()
      if commandSelector == #selector(NSResponder.moveUp(_:)) {
        guard !hasMarkedText else { return false }
        parent.onMove(.previous)
        return true
      }
      if commandSelector == #selector(NSResponder.moveDown(_:)) {
        guard !hasMarkedText else { return false }
        parent.onMove(.next)
        return true
      }
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        parent.onSubmit(hasMarkedText)
        return !hasMarkedText
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        parent.onEscape(hasMarkedText)
        return !hasMarkedText
      }
      return false
    }
  }
}
