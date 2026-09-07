import AppKit

/// Host-replaceable boundary for displaying the launcher panel.
///
/// The default implementation owns an AppKit panel. Integration fixtures and
/// embedding products can inject a deterministic presenter without creating a
/// window, while still exercising the public present/dismiss lifecycle.
@MainActor
public protocol LauncherPanelPresenting: AnyObject {
  var isVisible: Bool { get }
  /// Stable owner for system sheets launched from transient SwiftUI surfaces.
  /// Hosts without an AppKit window can keep the default `nil` implementation.
  var targetPickerPresentationWindow: NSWindow? { get }
  func showOnCurrentScreen()
  func dismiss()
  func invalidate()
}

extension LauncherPanelPresenting {
  public var targetPickerPresentationWindow: NSWindow? { nil }
}

/// Creates a fresh presenter for a module lifecycle. The factory is invoked
/// lazily on first presentation and again after a stop/start cycle.
public typealias LauncherPanelPresenterFactory = @MainActor (
  ShortcutLauncherModule
) -> any LauncherPanelPresenting
