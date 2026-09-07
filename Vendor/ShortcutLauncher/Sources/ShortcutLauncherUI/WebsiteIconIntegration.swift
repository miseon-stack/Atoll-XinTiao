import AppKit
import Foundation
import ShortcutLauncherCore
import UniformTypeIdentifiers

/// Optional management surface implemented by a full website-icon provider.
/// Render-only hosts may inject `WebsiteIconProviding` without adopting this
/// protocol; settings actions then remain safely unavailable.
public protocol WebsiteIconManaging: WebsiteIconProviding, WebsiteIconUpdateStreaming {
  func setOnlineFetchingEnabled(_ enabled: Bool) async
  func isOnlineFetchingEnabled() async -> Bool
  func clearAutomaticCache() async
  func storeCustomIcon(
    imageData: Data,
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation?
  func removeCustomIcon(
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation?
  func finalizeCustomIconMutation(_ mutation: CustomWebsiteIconMutation) async
}

extension WebsiteIconService: WebsiteIconManaging {}

/// Deterministic, network-free compatibility provider for low-level module
/// initializers. Production hosts that want automatic favicon discovery use
/// `ShortcutLauncherUIConfiguration`, whose default remains `WebsiteIconService`.
public struct EmptyWebsiteIconProvider: WebsiteIconProviding, Sendable {
  public init() {}

  public func icon(for request: WebsiteIconRequest) async -> WebsiteIconResult {
    fallback(for: request)
  }

  public func refresh(_ request: WebsiteIconRequest) async -> WebsiteIconResult {
    fallback(for: request)
  }

  public func cancelAll() async {}

  private func fallback(for request: WebsiteIconRequest) -> WebsiteIconResult {
    guard let origin = try? WebsiteOrigin(websiteURL: request.websiteURL) else {
      return .fallback(.generic)
    }
    return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
  }
}

/// Host-injectable boundary for the user-owned custom website icon picker.
@MainActor
public protocol WebsiteIconImagePickerPresenting: AnyObject {
  func chooseImage(presentationWindow: NSWindow?) async -> URL?
}

/// Default AppKit image picker. Bytes are still validated and normalized by
/// the icon service before they enter its managed asset directory.
@MainActor
public final class AppKitWebsiteIconImagePicker: WebsiteIconImagePickerPresenting {
  private var activePanel: NSOpenPanel?

  public init() {}

  public func chooseImage(presentationWindow: NSWindow?) async -> URL? {
    guard activePanel == nil else { return nil }
    let panel = NSOpenPanel()
    panel.message = "选择自定义网站图标"
    panel.prompt = "使用此图标"
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    panel.allowedContentTypes = [.png, .jpeg, .gif, .ico]
    activePanel = panel
    defer {
      if activePanel === panel { activePanel = nil }
    }

    NSApp.activate(ignoringOtherApps: true)
    let response = await withCheckedContinuation { continuation in
      let completion: (NSApplication.ModalResponse) -> Void = { [panel] response in
        _ = panel
        continuation.resume(returning: response)
      }
      if let presentationWindow,
        presentationWindow.isVisible,
        presentationWindow.attachedSheet == nil
      {
        panel.beginSheetModal(for: presentationWindow, completionHandler: completion)
      } else {
        panel.level = .floating
        panel.begin(completionHandler: completion)
        panel.orderFrontRegardless()
      }
    }
    return response == .OK ? panel.url : nil
  }
}

/// UI-only dependencies that an embedding product can replace without
/// changing the Core configuration schema or copying HostDemo code.
@MainActor
public struct ShortcutLauncherUIConfiguration {
  public var theme: LauncherTheme
  public var preferencesStore: (any LauncherUIPreferencesStoring)?
  public var applicationCatalog: any InstalledApplicationCataloging
  public var websiteIconProvider: any WebsiteIconProviding
  public var websiteIconImagePicker: any WebsiteIconImagePickerPresenting

  public init(
    theme: LauncherTheme = .standard,
    preferencesStore: (any LauncherUIPreferencesStoring)? = nil,
    applicationCatalog: any InstalledApplicationCataloging = InstalledApplicationCatalog.shared,
    websiteIconProvider: any WebsiteIconProviding = WebsiteIconService(),
    websiteIconImagePicker: any WebsiteIconImagePickerPresenting = AppKitWebsiteIconImagePicker()
  ) {
    self.theme = theme
    self.preferencesStore = preferencesStore
    self.applicationCatalog = applicationCatalog
    self.websiteIconProvider = websiteIconProvider
    self.websiteIconImagePicker = websiteIconImagePicker
  }
}
