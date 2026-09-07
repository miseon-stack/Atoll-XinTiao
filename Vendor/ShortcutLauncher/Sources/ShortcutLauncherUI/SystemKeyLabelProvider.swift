import AppKit
import Carbon
import Combine
import ShortcutLauncherCore

/// Injectable keyboard-label source used by views that render physical shortcut slots.
@MainActor
public protocol KeyLabelProviding: AnyObject {
  var snapshot: KeyLabelSnapshot { get }
  func refresh()
  func startObserving()
  func stopObserving()
}

extension KeyLabelProviding {
  /// Providers without an external event source need no lifecycle work.
  public func startObserving() {}
  public func stopObserving() {}
}

/// Publishes labels for the current ASCII-capable macOS keyboard layout.
///
/// Translation failure is intentionally harmless: each missing label falls back to the
/// fixed `KeySlotCatalog` label, and no persisted binding is ever rewritten.
@MainActor
public final class SystemKeyLabelProvider: NSObject, ObservableObject, KeyLabelProviding {
  public typealias LabelLoader = @MainActor () -> [UInt16: String]

  @Published public private(set) var snapshot: KeyLabelSnapshot

  private let labelLoader: LabelLoader
  private let observesInputSourceChanges: Bool
  private var isObservingInputSourceChanges = false

  public init(
    observesInputSourceChanges: Bool = true,
    labelLoader: @escaping LabelLoader = SystemKeyLabelProvider.loadSystemLabels
  ) {
    self.observesInputSourceChanges = observesInputSourceChanges
    self.labelLoader = labelLoader
    snapshot = .fallback()
    super.init()

    refresh()
  }

  deinit {
    if isObservingInputSourceChanges {
      DistributedNotificationCenter.default().removeObserver(self)
    }
  }

  public func startObserving() {
    guard observesInputSourceChanges, !isObservingInputSourceChanges else { return }
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(inputSourceDidChange(_:)),
      name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil
    )
    isObservingInputSourceChanges = true
  }

  public func stopObserving() {
    guard isObservingInputSourceChanges else { return }
    DistributedNotificationCenter.default().removeObserver(self)
    isObservingInputSourceChanges = false
  }

  public func refresh() {
    let loaded = labelLoader()
    let labels = Dictionary(uniqueKeysWithValues: KeySlotCatalog.all.map { slot in
      let translated = loaded[slot.keyCode]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (slot.keyCode, translated.flatMap { $0.isEmpty ? nil : $0 } ?? slot.fallbackLabel)
    })
    snapshot = KeyLabelSnapshot(revision: snapshot.revision &+ 1, labels: labels)
  }

  @objc private func inputSourceDidChange(_ notification: Notification) {
    guard isObservingInputSourceChanges else { return }
    refresh()
  }

  /// Deterministic seam for lifecycle tests without posting a process-wide
  /// distributed notification.
  func simulateInputSourceChangeForTesting() {
    inputSourceDidChange(Notification(name: Notification.Name("test-input-source-change")))
  }

  /// Reads only the current ASCII-capable layout. This does not monitor global keystrokes
  /// and requires neither Accessibility nor Input Monitoring permission.
  public static func loadSystemLabels() -> [UInt16: String] {
    guard let unmanagedSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else {
      return [:]
    }
    let source = unmanagedSource.takeRetainedValue()
    guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return [:] }

    let data = unsafeBitCast(property, to: CFData.self)
    guard let bytes = CFDataGetBytePtr(data) else { return [:] }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    let keyboardType = UInt32(LMGetKbdType())
    var result: [UInt16: String] = [:]

    for slot in KeySlotCatalog.all {
      var deadKeyState: UInt32 = 0
      var actualLength = 0
      var characters = [UniChar](repeating: 0, count: 8)
      let status = characters.withUnsafeMutableBufferPointer { buffer in
        UCKeyTranslate(
          layout,
          slot.keyCode,
          UInt16(kUCKeyActionDisplay),
          0,
          keyboardType,
          OptionBits(kUCKeyTranslateNoDeadKeysBit),
          &deadKeyState,
          buffer.count,
          &actualLength,
          buffer.baseAddress
        )
      }
      guard status == noErr, actualLength > 0 else { continue }

      let value = String(utf16CodeUnits: characters, count: actualLength)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let containsNonPrintableScalar = value.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0)
          || CharacterSet.newlines.contains($0)
      }
      guard !value.isEmpty, !containsNonPrintableScalar else {
        continue
      }
      result[slot.keyCode] = value.uppercased()
    }
    return result
  }
}
