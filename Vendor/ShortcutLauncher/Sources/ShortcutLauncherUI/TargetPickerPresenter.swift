import AppKit
import ShortcutLauncherCore
import UniformTypeIdentifiers

/// Window-system boundary for selecting local launch targets.
@MainActor
public protocol TargetPickerPresenting: AnyObject {
  func chooseTarget(kind: LaunchTargetKind, panelKeyLabel: String) -> URL?
  func chooseTargetAsync(kind: LaunchTargetKind, panelKeyLabel: String) async -> URL?
  func chooseTargetAsync(
    kind: LaunchTargetKind,
    panelKeyLabel: String,
    presentationWindow: NSWindow?
  ) async -> URL?
}

extension TargetPickerPresenting {
  /// Compatibility fallback for injected hosts that only implement the
  /// original synchronous picker boundary.
  public func chooseTargetAsync(kind: LaunchTargetKind, panelKeyLabel: String) async -> URL? {
    chooseTarget(kind: kind, panelKeyLabel: panelKeyLabel)
  }

  /// Owner-aware fallback preserves source compatibility with hosts that
  /// already supplied the original async boundary.
  public func chooseTargetAsync(
    kind: LaunchTargetKind,
    panelKeyLabel: String,
    presentationWindow: NSWindow?
  ) async -> URL? {
    await chooseTargetAsync(kind: kind, panelKeyLabel: panelKeyLabel)
  }
}

/// Default AppKit implementation. It returns only the selected URL; binding
/// identity, bookmark creation and persistence remain owned by the module.
@MainActor
public final class AppKitTargetPickerPresenter: TargetPickerPresenting {
  private var activePanel: NSOpenPanel?

  public init() {}

  public func chooseTarget(kind: LaunchTargetKind, panelKeyLabel: String) -> URL? {
    guard let panel = configuredPanel(kind: kind, panelKeyLabel: panelKeyLabel) else { return nil }
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  public func chooseTargetAsync(
    kind: LaunchTargetKind,
    panelKeyLabel: String
  ) async -> URL? {
    await chooseTargetAsync(
      kind: kind,
      panelKeyLabel: panelKeyLabel,
      presentationWindow: nil
    )
  }

  public func chooseTargetAsync(
    kind: LaunchTargetKind,
    panelKeyLabel: String,
    presentationWindow: NSWindow?
  ) async -> URL? {
    guard let panel = configuredPanel(kind: kind, panelKeyLabel: panelKeyLabel) else { return nil }
    guard activePanel == nil else { return nil }
    activePanel = panel
    defer {
      if activePanel === panel { activePanel = nil }
    }

    NSApp.activate(ignoringOtherApps: true)
    let response = await withCheckedContinuation { continuation in
      let completion: (NSApplication.ModalResponse) -> Void = { [panel] response in
        // Capturing the panel makes its lifetime explicit for the whole
        // asynchronous presentation, including hosts that do not retain it.
        _ = panel
        continuation.resume(returning: response)
      }
      if let presentationWindow,
        presentationWindow.isVisible,
        presentationWindow.attachedSheet == nil
      {
        panel.beginSheetModal(for: presentationWindow, completionHandler: completion)
      } else {
        // A host may embed the module without exposing a window. Keep the
        // fallback above ordinary windows so a floating launcher cannot cover
        // the system picker.
        panel.level = .floating
        panel.begin(completionHandler: completion)
        panel.orderFrontRegardless()
      }
    }
    return response == .OK ? panel.url : nil
  }

  private func configuredPanel(
    kind: LaunchTargetKind,
    panelKeyLabel: String
  ) -> NSOpenPanel? {
    guard kind != .web else { return nil }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.canCreateDirectories = false

    switch kind {
    case .application:
      panel.message = "选择要绑定到 \(panelKeyLabel) 的应用"
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowedContentTypes = [.application]
    case .file:
      panel.message = "选择要绑定到 \(panelKeyLabel) 的文件"
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
    case .folder:
      panel.message = "选择要绑定到 \(panelKeyLabel) 的文件夹"
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
    case .web:
      return nil
    }
    return panel
  }
}
