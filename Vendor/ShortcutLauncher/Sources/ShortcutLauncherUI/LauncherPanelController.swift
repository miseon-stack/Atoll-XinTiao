import AppKit
import OSLog
import ShortcutLauncherCore
import SwiftUI

@MainActor
final class LauncherPanelController: NSWindowController, NSWindowDelegate,
  LauncherPanelPresenting
{
  private let logger = Logger(
    subsystem: "io.github.miseon-stack.shortcutlauncher",
    category: "panel"
  )
  private weak var module: ShortcutLauncherModule?
  private var eventMonitor: Any?
  private var presentationVisibleFrame: NSRect?
  private var presentationRevision: UInt = 0
  private let preferredPanelSize = NSSize(width: 1080, height: 570)
  private let compactMinimumPanelSize = NSSize(width: 320, height: 260)

  var isVisible: Bool {
    window?.isVisible == true
  }

  var targetPickerPresentationWindow: NSWindow? { window }

  init(module: ShortcutLauncherModule) {
    self.module = module

    let panel = FocusablePanel(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 570),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "快捷启动"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.setAccessibilityIdentifier("launcher.panel.window")
    panel.isReleasedWhenClosed = false
    panel.isRestorable = false
    panel.level = .floating
    panel.hidesOnDeactivate = true
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.minSize = compactMinimumPanelSize
    panel.contentViewController = NSHostingController(
      rootView: LauncherPanelView(module: module)
        .launcherTheme(module.launcherTheme)
    )

    super.init(window: panel)
    panel.delegate = self
    shouldCascadeWindows = false
    installEventMonitor()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenParametersDidChange(_:)),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func showOnCurrentScreen() {
    guard let window else {
      logger.error("panel_show_failed reason=missing_window")
      return
    }
    logger.notice("panel_show_requested was_visible=\(window.isVisible, privacy: .public)")
    presentationRevision &+= 1
    let revision = presentationRevision

    let mouseLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    presentationVisibleFrame = screen?.visibleFrame

    // NSWindowController may cascade a window the first time it is shown. Show it
    // before calculating the final frame, then clamp the actual laid-out size to
    // the screen that contains the pointer.
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)

    window.contentView?.layoutSubtreeIfNeeded()
    if let visibleFrame = presentationVisibleFrame {
      position(window, inside: visibleFrame)
    }

    window.orderFrontRegardless()
    window.makeKeyAndOrderFront(nil)
    logger.notice("panel_show_immediate visible=\(window.isVisible, privacy: .public)")

    // SwiftUI may publish the hosting view's final fitting size on the next run
    // loop during the first presentation. Clamp once more after that size lands.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak window] in
      guard let self, let window, self.presentationRevision == revision else { return }
      // Status-item actions run inside a menu tracking loop. Confirm activation
      // after that loop exits so hidesOnDeactivate cannot immediately hide the
      // panel and make “打开面板” appear to do nothing.
      NSApp.activate(ignoringOtherApps: true)
      window.orderFrontRegardless()
      window.makeKeyAndOrderFront(nil)
      self.logger.notice(
        "panel_show_confirmed visible=\(window.isVisible, privacy: .public) active_space=\(window.isOnActiveSpace, privacy: .public) number=\(window.windowNumber, privacy: .public)"
      )
      if let visibleFrame = self.presentationVisibleFrame {
        self.position(window, inside: visibleFrame)
      }
    }
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === self.window,
      window.isVisible,
      let visibleFrame = presentationVisibleFrame
    else { return }

    // The hosting controller can replace the temporary zero-width frame with its
    // final fitting size after either of the scheduled positioning passes. A
    // resize notification is the reliable point at which that final size exists.
    position(window, inside: visibleFrame)
  }

  func windowDidChangeScreen(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      window === self.window,
      window.isVisible,
      let visibleFrame = window.screen?.visibleFrame
    else { return }
    presentationVisibleFrame = visibleFrame
    position(window, inside: visibleFrame)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === window else { return true }
    if let module {
      module.dismissPanel()
    } else {
      dismiss()
    }
    return false
  }

  private func position(_ window: NSWindow, inside visibleFrame: NSRect) {
    // AppKit enforces `minSize` after `setFrame`. Lower it per-axis when a
    // constrained display (or enlarged Dock/menu bar) offers less room, so the
    // pure geometry result remains physically attainable by the real window.
    window.minSize = NSSize(
      width: min(compactMinimumPanelSize.width, max(1, visibleFrame.width - 24)),
      height: min(compactMinimumPanelSize.height, max(1, visibleFrame.height - 24))
    )
    let frame = PanelGeometry.frame(
      preferredSize: resolvedPreferredSize(for: window),
      inside: visibleFrame,
      margin: 12
    )
    guard frame.width > 1, frame.height > 1 else { return }
    guard abs(window.frame.origin.x - frame.origin.x) > 0.5
      || abs(window.frame.origin.y - frame.origin.y) > 0.5
      || abs(window.frame.width - frame.width) > 0.5
      || abs(window.frame.height - frame.height) > 0.5
    else { return }
    window.setFrame(frame, display: false)
  }

  func dismiss() {
    presentationRevision &+= 1
    // This panel is reused for every invocation. NSWindowController.close() can
    // detach its window after the first execution, making later menu/hotkey
    // requests silently no-op. Hiding preserves the window and SwiftUI state.
    window?.orderOut(nil)
    logger.notice("panel_hidden window_retained=\(self.window != nil, privacy: .public)")
  }

  func invalidate() {
    presentationRevision &+= 1
    window?.delegate = nil
    window?.contentViewController = nil
    close()
    window = nil
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    NotificationCenter.default.removeObserver(
      self,
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
  }

  @objc private func screenParametersDidChange(_ notification: Notification) {
    guard let window, window.isVisible else { return }
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? window.screen
      ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else { return }
    presentationVisibleFrame = visibleFrame
    position(window, inside: visibleFrame)
  }

  private func resolvedPreferredSize(for window: NSWindow) -> NSSize {
    window.contentView?.layoutSubtreeIfNeeded()
    guard let fittingSize = window.contentView?.fittingSize,
      fittingSize.width > window.minSize.width,
      fittingSize.height > window.minSize.height
    else { return preferredPanelSize }
    return NSSize(
      width: min(preferredPanelSize.width, fittingSize.width),
      height: min(preferredPanelSize.height, fittingSize.height)
    )
  }

  private func installEventMonitor() {
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { [weak self] event in
      guard let self,
        self.isVisible,
        event.window === self.window
      else {
        return event
      }

      // SwiftUI sheets share the panel's event stream. Their controls (most
      // importantly the shortcut recorder) must receive keys without the
      // underlying 38-slot dispatcher interpreting them as panel actions.
      if self.window?.attachedSheet != nil
        || self.module?.bindingRequestKeyCode != nil
        || self.module?.quickBindingRequestKeyCode != nil
      {
        return event
      }

      if self.window?.firstResponder is NSTextView
        || self.window?.firstResponder is LocalHotkeyRecorderNSView
      {
        return event
      }

      return self.module?.handlePanelEvent(event) == true ? nil : event
    }
  }
}

private final class FocusablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
