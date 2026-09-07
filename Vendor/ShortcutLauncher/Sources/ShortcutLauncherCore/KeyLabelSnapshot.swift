import Foundation

/// Immutable keyboard-layout labels. Physical key codes remain the execution identity.
public struct KeyLabelSnapshot: Equatable, Sendable {
  public let revision: UInt64
  public let labels: [UInt16: String]

  public init(revision: UInt64, labels: [UInt16: String]) {
    self.revision = revision
    self.labels = labels
  }

  public func label(for keyCode: UInt16) -> String {
    guard let label = labels[keyCode]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !label.isEmpty
    else {
      return KeySlotCatalog.label(for: keyCode)
    }
    return label
  }

  public func displayName(for hotkey: HotkeyDefinition) -> String {
    "\(hotkey.modifiers.displayName)\(label(for: hotkey.keyCode))"
  }

  public static func fallback(revision: UInt64 = 0) -> KeyLabelSnapshot {
    KeyLabelSnapshot(
      revision: revision,
      labels: Dictionary(uniqueKeysWithValues: KeySlotCatalog.all.map {
        ($0.keyCode, $0.fallbackLabel)
      })
    )
  }
}
