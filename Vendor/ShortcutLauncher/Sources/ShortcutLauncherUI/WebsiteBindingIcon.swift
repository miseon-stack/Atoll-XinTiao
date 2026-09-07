import ShortcutLauncherCore
import SwiftUI

/// Keeps one slot's icon model alive while the card is visible. Ordinary card
/// rendering is deliberately cache-only; a new binding or explicit refresh is
/// what authorizes network discovery in `WebsiteIconService`.
struct WebsiteBindingIcon: View {
  @StateObject private var model: WebsiteIconPresentationModel

  private let request: WebsiteIconRequest
  private let size: CGFloat

  init(
    bindingID: BindingID,
    websiteURL: URL,
    provider: any WebsiteIconProviding,
    size: CGFloat
  ) {
    request = WebsiteIconRequest(
      bindingID: bindingID,
      websiteURL: websiteURL,
      reason: .passiveDisplay
    )
    self.size = size
    _model = StateObject(wrappedValue: WebsiteIconPresentationModel(provider: provider))
  }

  var body: some View {
    WebsiteIconView(presentation: model.presentation, size: size)
      .onAppear { model.load(request) }
      .onChange(of: requestIdentity) { _, _ in model.load(request) }
      .onDisappear { model.cancel() }
      .accessibilityHidden(true)
  }

  private var requestIdentity: String {
    "\(request.bindingID.rawValue)|\(request.websiteURL.absoluteString)"
  }
}
