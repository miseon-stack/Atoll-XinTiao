import AppKit
import Darwin
import OSLog
import ShortcutLauncherCore
import ShortcutLauncherUI
import SwiftUI

@main
enum ShortcutLauncherHostDemoMain {
  @MainActor
  static func main() {
    let options: HostDemoLaunchOptions
    do {
      options = try HostDemoLaunchOptions(arguments: CommandLine.arguments)
    } catch {
      let message = "ShortcutLauncherHostDemo: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(EX_USAGE)
    }

    let application = NSApplication.shared
    let delegate = HostDemoAppDelegate(options: options)
    application.delegate = delegate
    if options.isUITesting {
      application.mainMenu = makeUITestingMainMenu()
    }
    application.setActivationPolicy(
      options.autoShowPanel || options.isUITesting ? .regular : .accessory)
    application.run()
  }

  /// Keeps UI-test accessibility snapshots limited to deterministic fixture UI.
  /// In particular, AppKit's implicit application menu can expose the host
  /// account's recent-document names even though the launcher never reads them.
  @MainActor
  private static func makeUITestingMainMenu() -> NSMenu {
    let rootMenu = NSMenu(title: "UI Testing")
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu(title: "UI Testing")
    applicationMenu.addItem(
      withTitle: "退出 UI 测试",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: ""
    )
    applicationItem.submenu = applicationMenu
    rootMenu.addItem(applicationItem)
    return rootMenu
  }
}

private struct HostDemoLaunchOptions {
  let autoShowPanel: Bool
  let storageDirectoryOverride: URL?
  let isUITesting: Bool
  let fixture: UITestingFixture?
  let usesFakeHotkeyRegistrar: Bool
  let usesFakeTargetOpener: Bool
  let allowsExistingUITestStorage: Bool
  let quickBindingSlot: UInt16?
  let usesVisualCaptureWindowLevel: Bool

  init(arguments: [String]) throws {
    autoShowPanel = arguments.contains("--show-panel")
    isUITesting = arguments.contains("--ui-testing")

    let fixtureValue = try Self.commandLineValue(after: "--fixture", in: arguments)
    let storageValue = try Self.commandLineValue(after: "--storage-directory", in: arguments)
    usesFakeHotkeyRegistrar = arguments.contains("--fake-hotkey-registrar")
    usesFakeTargetOpener = arguments.contains("--fake-target-opener")
    allowsExistingUITestStorage = arguments.contains("--reuse-ui-test-storage")
    usesVisualCaptureWindowLevel = arguments.contains("--visual-capture")
    let quickBindingSlotValue = try Self.commandLineValue(
      after: "--quick-binding-slot",
      in: arguments
    )
    if let quickBindingSlotValue {
      guard let slot = UInt16(quickBindingSlotValue),
        KeySlotCatalog.allowedKeyCodes.contains(slot)
      else { throw HostDemoLaunchError.invalidQuickBindingSlot }
      quickBindingSlot = slot
    } else {
      quickBindingSlot = nil
    }

    let hasUITestingOnlyOption =
      fixtureValue != nil
      || usesFakeHotkeyRegistrar
      || usesFakeTargetOpener
      || allowsExistingUITestStorage
      || quickBindingSlot != nil
      || usesVisualCaptureWindowLevel
    guard isUITesting || !hasUITestingOnlyOption else {
      throw HostDemoLaunchError.uiTestingFlagRequired
    }

    if isUITesting {
      guard let storageValue else {
        throw HostDemoLaunchError.uiTestingStorageRequired
      }
      storageDirectoryOverride = URL(fileURLWithPath: storageValue, isDirectory: true)
      fixture = try fixtureValue.map(UITestingFixture.init(argument:))
    } else {
      storageDirectoryOverride = storageValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
      fixture = nil
    }
  }

  private static func commandLineValue(after flag: String, in arguments: [String]) throws -> String?
  {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex,
      !arguments[valueIndex].hasPrefix("--")
    else {
      throw HostDemoLaunchError.missingOptionValue(flag)
    }
    return arguments[valueIndex]
  }
}

private enum HostDemoLaunchError: LocalizedError {
  case missingOptionValue(String)
  case uiTestingFlagRequired
  case uiTestingStorageRequired
  case uiTestingStorageMustBeNew
  case uiTestingStorageMustBeTemporary
  case unknownFixture(String)
  case invalidQuickBindingSlot

  var errorDescription: String? {
    switch self {
    case .missingOptionValue(let flag):
      "\(flag) 缺少参数值。"
    case .uiTestingFlagRequired:
      "fixture、平台 fake、测试存储复用、视觉捕获和快速绑定槽位参数仅可与 --ui-testing 一起使用。"
    case .uiTestingStorageRequired:
      "--ui-testing 必须同时指定 --storage-directory。"
    case .uiTestingStorageMustBeNew:
      "UI 测试存储目录必须是尚不存在的新目录。"
    case .uiTestingStorageMustBeTemporary:
      "UI 测试存储目录必须位于系统临时目录中。"
    case .unknownFixture(let name):
      "未知 UI 测试 fixture：\(name)。"
    case .invalidQuickBindingSlot:
      "--quick-binding-slot 必须是 38 键目录中的物理 keyCode。"
    }
  }
}

private enum UITestingFixture: String, CaseIterable {
  case empty
  case onePanelOnly = "one-panel-only"
  case oneDirect = "one-direct"
  case runtimeConflict = "runtime-conflict"
  case missingFile = "missing-file"
  case all38 = "all-38"

  init(argument: String) throws {
    guard let fixture = Self(rawValue: argument) else {
      throw HostDemoLaunchError.unknownFixture(argument)
    }
    self = fixture
  }

  func configuration(storageDirectory: URL) -> LauncherConfiguration {
    switch self {
    case .empty:
      return LauncherConfiguration()
    case .onePanelOnly:
      return configuration(
        binding: webBinding(
          keyCode: PhysicalKeyCode.q,
          id: "ui-fixture-panel-only",
          displayName: "Panel Fixture",
          path: "panel-only"
        )
      )
    case .oneDirect:
      return configuration(
        directModeEnabled: true,
        binding: webBinding(
          keyCode: PhysicalKeyCode.q,
          id: "ui-fixture-direct",
          displayName: "Direct Fixture",
          path: "direct",
          directHotkey: HotkeyDefinition(
            keyCode: PhysicalKeyCode.q,
            modifiers: [.command, .option]
          )
        )
      )
    case .runtimeConflict:
      return configuration(
        directModeEnabled: true,
        binding: webBinding(
          keyCode: PhysicalKeyCode.q,
          id: "ui-fixture-conflict",
          displayName: "Conflict Fixture",
          path: "conflict",
          directHotkey: HotkeyDefinition(
            keyCode: PhysicalKeyCode.q,
            modifiers: [.command, .shift]
          )
        )
      )
    case .missingFile:
      let target = LaunchTarget(
        kind: .file,
        displayName: "Missing Fixture",
        lastKnownURL: storageDirectory.appendingPathComponent("missing-fixture.txt")
      )
      return configuration(
        binding: BindingRecord(
          id: BindingID(rawValue: "ui-fixture-missing-file"),
          physicalKeyCode: PhysicalKeyCode.q,
          target: target
        ))
    case .all38:
      let bindings = Dictionary(
        uniqueKeysWithValues: KeySlotCatalog.all.map { slot in
          let target = LaunchTarget(
            kind: .web,
            displayName: "Fixture \(slot.fallbackLabel)",
            lastKnownURL: URL(string: "https://fixture.invalid/slot/\(slot.keyCode)")!
          )
          return (
            slot.keyCode,
            BindingRecord(
              id: BindingID(rawValue: "ui-fixture-slot-\(slot.keyCode)"),
              physicalKeyCode: slot.keyCode,
              target: target
            )
          )
        })
      return LauncherConfiguration(bindings: bindings)
    }
  }

  private func configuration(
    directModeEnabled: Bool = false,
    binding: BindingRecord
  ) -> LauncherConfiguration {
    LauncherConfiguration(
      directModeEnabled: directModeEnabled,
      bindings: [binding.physicalKeyCode: binding]
    )
  }

  private func webBinding(
    keyCode: UInt16,
    id: String,
    displayName: String,
    path: String,
    directHotkey: HotkeyDefinition? = nil
  ) -> BindingRecord {
    BindingRecord(
      id: BindingID(rawValue: id),
      physicalKeyCode: keyCode,
      target: LaunchTarget(
        kind: .web,
        displayName: displayName,
        lastKnownURL: URL(string: "https://fixture.invalid/\(path)")!
      ),
      directHotkey: directHotkey
    )
  }
}

@MainActor
private final class HostDemoAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let logger = Logger(
    subsystem: "io.github.miseon-stack.shortcutlauncher.hostdemo",
    category: "lifecycle"
  )
  private let options: HostDemoLaunchOptions
  private var module: ShortcutLauncherModule?
  private var statusItem: NSStatusItem?
  private var directModeMenuItem: NSMenuItem?

  init(options: HostDemoLaunchOptions) {
    self.options = options
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let storageDirectory = try makeStorageDirectory()
      let setup = makeModule(storageDirectory: storageDirectory)
      module = setup.module
      configureStatusItem()

      Task { @MainActor in
        do {
          if let fixture = options.fixture, let repository = setup.testingRepository {
            try await repository.save(fixture.configuration(storageDirectory: storageDirectory))
          }
          try await setup.module.start()
          refreshStatusMenu()
          logger.notice("shortcut_launcher_started")
          if options.autoShowPanel {
            setup.module.presentPanel()
            if let quickBindingSlot = options.quickBindingSlot {
              setup.module.requestQuickBinding(for: quickBindingSlot)
            }
          }
        } catch {
          logger.error(
            "shortcut_launcher_start_failed detail=\(error.localizedDescription, privacy: .private)"
          )
          showStartupError(error)
        }
      }
    } catch {
      logger.error(
        "shortcut_launcher_setup_failed detail=\(error.localizedDescription, privacy: .private)")
      showStartupError(error)
    }
  }

  private func makeStorageDirectory() throws -> URL {
    guard let storageDirectoryOverride = options.storageDirectoryOverride else {
      let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      return
        base
        .appendingPathComponent("ShortcutLauncherHostDemo", isDirectory: true)
        .appendingPathComponent("ShortcutLauncher", isDirectory: true)
    }

    let requested = storageDirectoryOverride.standardizedFileURL
    guard options.isUITesting else { return requested }

    let requestedParent =
      requested
      .deletingLastPathComponent()
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard isSystemTemporaryPath(requestedParent) else {
      throw HostDemoLaunchError.uiTestingStorageMustBeTemporary
    }
    if FileManager.default.fileExists(atPath: requested.path) {
      guard options.allowsExistingUITestStorage else {
        throw HostDemoLaunchError.uiTestingStorageMustBeNew
      }
      return requested
    }
    try FileManager.default.createDirectory(
      at: requested,
      withIntermediateDirectories: false
    )
    return requested
  }

  private func isSystemTemporaryPath(_ url: URL) -> Bool {
    let path = url.path
    if path == "/tmp" || path.hasPrefix("/tmp/")
      || path == "/private/tmp" || path.hasPrefix("/private/tmp/")
    {
      return true
    }

    // XCUITest and the launched application can receive different TMPDIR values,
    // while both remain inside Darwin's per-user /var/folders/.../T tree.
    guard path.hasPrefix("/private/var/folders/") else { return false }
    return path.split(separator: "/").contains("T")
  }

  private func makeModule(storageDirectory: URL) -> HostDemoModuleSetup {
    let websiteIconService = WebsiteIconService(
      cacheDirectoryURL: websiteIconCacheDirectory(storageDirectory: storageDirectory),
      customIconsDirectoryURL: storageDirectory.appendingPathComponent(
        "WebsiteIcons-Custom-v1",
        isDirectory: true
      )
    )

    guard options.isUITesting else {
      return HostDemoModuleSetup(
        module: ShortcutLauncherModule(
          hostConfiguration: ShortcutLauncherHostConfiguration(
            storageDirectory: storageDirectory
          ),
          uiConfiguration: ShortcutLauncherUIConfiguration(
            websiteIconProvider: websiteIconService
          )
        ),
        testingRepository: nil
      )
    }

    let repository = ConfigurationRepository(storageDirectory: storageDirectory)
    let registrar: any HotkeyRegistering =
      options.usesFakeHotkeyRegistrar
      ? UITestingHotkeyRegistrar(rejectsDirectRegistration: options.fixture == .runtimeConflict)
      : CarbonHotkeyRegistrar()
    let opener: any WorkspaceOpening =
      options.usesFakeTargetOpener
      ? UITestingTargetOpener()
      : NSWorkspaceTargetOpener()
    let module = ShortcutLauncherModule(
      registrar: registrar,
      repository: repository,
      bookmarkResolver: FoundationBookmarkResolver(),
      opener: opener,
      ownerLease: .processShared,
      keyLabelProvider: SystemKeyLabelProvider(),
      presentsRepairUIOnDirectFailure: false,
      panelPresenterFactory: { module in
        UITestingPanelPresenter(
          module: module,
          keepsAboveAllApps: !self.options.usesVisualCaptureWindowLevel
        )
      },
      websiteIconProvider: websiteIconService
    )
    return HostDemoModuleSetup(module: module, testingRepository: repository)
  }

  /// An explicit storage override is a containment boundary used by acceptance
  /// and embedding smoke runs. Keep every generated icon byte beneath it. A
  /// normal HostDemo launch uses the host's own Caches container instead.
  private func websiteIconCacheDirectory(storageDirectory: URL) -> URL {
    if options.storageDirectoryOverride != nil {
      return storageDirectory.appendingPathComponent(
        "WebsiteIcons-Automatic-v1",
        isDirectory: true
      )
    }
    let cachesRoot =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? storageDirectory
    return
      cachesRoot
      .appendingPathComponent("ShortcutLauncherHostDemo", isDirectory: true)
      .appendingPathComponent("ShortcutLauncher", isDirectory: true)
      .appendingPathComponent("WebsiteIcons-Automatic-v1", isDirectory: true)
  }

  private func configureStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "keyboard",
      accessibilityDescription: "快捷键启动模块"
    )

    let menu = NSMenu()
    menu.addItem(menuItem(title: "打开面板", action: #selector(openPanel)))
    menu.addItem(.separator())
    let directModeItem = menuItem(
      title: "启用全局快捷键",
      action: #selector(toggleDirectHotkeys)
    )
    directModeItem.state = .off
    menu.addItem(directModeItem)
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "退出", action: #selector(quit)))
    menu.delegate = self
    item.menu = menu
    directModeMenuItem = directModeItem
    statusItem = item
    refreshStatusMenu()
  }

  private func menuItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func openPanel() {
    logger.notice("open_panel_menu_selected")
    module?.presentPanel()
  }

  @objc private func toggleDirectHotkeys() {
    guard let module, !module.isCommitting, !module.isEditing else {
      refreshStatusMenu()
      return
    }
    let shouldEnable = !module.currentConfiguration.directModeEnabled
    directModeMenuItem?.isEnabled = false
    Task { @MainActor in
      await module.setDirectModeEnabled(shouldEnable)
      refreshStatusMenu()
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    refreshStatusMenu()
  }

  private func refreshStatusMenu() {
    guard let module, let directModeMenuItem else {
      directModeMenuItem?.state = .off
      directModeMenuItem?.isEnabled = false
      return
    }
    directModeMenuItem.state = module.currentConfiguration.directModeEnabled ? .on : .off
    directModeMenuItem.isEnabled = !module.isCommitting && !module.isEditing
  }

  @objc private func quit() {
    guard let module else {
      NSApp.terminate(nil)
      return
    }
    Task { @MainActor in
      await module.stop()
      NSApp.terminate(nil)
    }
  }

  private func showStartupError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "快捷键启动模块启动失败"
    switch error as? LauncherError {
    case .moduleAlreadyActive:
      alert.informativeText = "同一进程中已有一个快捷启动模块正在运行。"
    case .unsupportedFutureSchema(let version):
      alert.informativeText = "配置来自更新版本（schema \(version)），当前版本没有修改该文件。"
    default:
      alert.informativeText = "模块未能启动。原配置仍保留，请检查文件权限或快捷键占用后重试。"
    }
    alert.addButton(withTitle: "退出")
    alert.runModal()
    NSApp.terminate(nil)
  }
}

private struct HostDemoModuleSetup {
  let module: ShortcutLauncherModule
  let testingRepository: ConfigurationRepository?
}

/// A deterministic shell around the production SwiftUI panel, used only by
/// `--ui-testing`. It remains visible if another desktop process activates and
/// uses a high test-only window level so synthesized clicks cannot land in an
/// unrelated user window. Production launches still use LauncherPanelController.
@MainActor
private final class UITestingPanelPresenter: NSObject, LauncherPanelPresenting,
  NSWindowDelegate
{
  private weak var module: ShortcutLauncherModule?
  private var panel: NSPanel?

  var isVisible: Bool { panel?.isVisible == true }
  var targetPickerPresentationWindow: NSWindow? { panel }

  init(module: ShortcutLauncherModule, keepsAboveAllApps: Bool = true) {
    self.module = module
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 570),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "快捷启动 UI 验收"
    panel.setAccessibilityIdentifier("launcher.panel.window")
    panel.isReleasedWhenClosed = false
    panel.isRestorable = false
    panel.hidesOnDeactivate = false
    panel.level = keepsAboveAllApps ? .screenSaver : .floating
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.minSize = NSSize(width: 320, height: 260)
    panel.contentViewController = NSHostingController(
      rootView: LauncherPanelView(module: module)
        .launcherTheme(module.launcherTheme)
    )
    self.panel = panel
    super.init()
    panel.delegate = self
  }

  func showOnCurrentScreen() {
    guard let panel else { return }
    if let visibleFrame = NSScreen.main?.visibleFrame {
      // NSHostingController initially reports the launcher's compact minimum
      // fitting size. The deterministic fixture should still exercise the real
      // 38-key desktop layout rather than capture a 300-point scroll viewport.
      let width = min(1080, max(320, visibleFrame.width - 24))
      let height = min(570, max(260, visibleFrame.height - 24))
      panel.setFrame(
        NSRect(
          x: visibleFrame.midX - width / 2,
          y: visibleFrame.midY - height / 2,
          width: width,
          height: height
        ),
        display: false
      )
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()
    panel.makeKeyAndOrderFront(nil)
  }

  func dismiss() {
    panel?.orderOut(nil)
  }

  func invalidate() {
    panel?.delegate = nil
    panel?.contentViewController = nil
    panel?.close()
    panel = nil
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    module?.dismissPanel()
    return false
  }
}

@MainActor
private final class UITestingHotkeyRegistrar: HotkeyRegistering {
  private let rejectsDirectRegistration: Bool
  private var registrations: [HotkeyID: HotkeyDefinition] = [:]
  private var handler: (@MainActor @Sendable (HotkeyID) -> Void)?

  init(rejectsDirectRegistration: Bool) {
    self.rejectsDirectRegistration = rejectsDirectRegistration
  }

  func setHandler(_ handler: @escaping @MainActor @Sendable (HotkeyID) -> Void) {
    self.handler = handler
  }

  func register(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    if rejectsDirectRegistration, case .direct = id {
      throw LauncherError.hotkeyRegistrationFailed(status: -1)
    }
    guard registrations.values.contains(hotkey) == false else {
      throw LauncherError.hotkeyRegistrationFailed(status: -2)
    }
    registrations[id] = hotkey
  }

  func replace(_ hotkey: HotkeyDefinition, id: HotkeyID) async throws {
    registrations.removeValue(forKey: id)
    try await register(hotkey, id: id)
  }

  func reassign(
    _ hotkey: HotkeyDefinition,
    from oldID: HotkeyID,
    to newID: HotkeyID
  ) async throws {
    registrations.removeValue(forKey: oldID)
    try await register(hotkey, id: newID)
  }

  func unregister(id: HotkeyID) async {
    registrations.removeValue(forKey: id)
  }

  func unregisterAll() async {
    registrations.removeAll()
  }

  func shutdown() async {
    registrations.removeAll()
    handler = nil
  }
}

@MainActor
private final class UITestingTargetOpener: WorkspaceOpening {
  func open(target: LaunchTarget, resolvedURL: URL) async throws {
    if target.displayName == "Missing Fixture" {
      throw LauncherError.targetUnavailable
    }
  }
}
