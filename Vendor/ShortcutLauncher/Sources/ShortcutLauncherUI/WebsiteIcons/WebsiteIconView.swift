import AppKit
import ShortcutLauncherCore
import SwiftUI

@MainActor
public final class WebsiteIconPresentationModel: ObservableObject {
  @Published public private(set) var presentation: WebsiteIconPresentation

  private let provider: any WebsiteIconProviding
  private var request: WebsiteIconRequest?
  private var generation: UInt64 = 0
  private var loadTask: Task<Void, Never>?
  private var updatesTask: Task<Void, Never>?

  public init(
    provider: any WebsiteIconProviding,
    initialPresentation: WebsiteIconPresentation = .fallback(.generic, isLoading: false)
  ) {
    self.provider = provider
    presentation = initialPresentation
    if let streamingProvider = provider as? any WebsiteIconUpdateStreaming {
      updatesTask = Task { [weak self] in
        let stream = await streamingProvider.updates()
        for await update in stream {
          guard !Task.isCancelled else { break }
          self?.receive(update)
        }
      }
    }
  }

  deinit {
    loadTask?.cancel()
    updatesTask?.cancel()
  }

  public func load(_ request: WebsiteIconRequest) {
    generation &+= 1
    let currentGeneration = generation
    self.request = request
    loadTask?.cancel()
    if let origin = try? WebsiteOrigin(websiteURL: request.websiteURL) {
      presentation = .fallback(
        WebsiteIconFallbackDescriptor(origin: origin),
        isLoading: request.reason != .passiveDisplay
      )
    } else {
      presentation = .fallback(.generic, isLoading: false)
    }
    loadTask = Task { [weak self, provider] in
      let result = await provider.icon(for: request)
      guard !Task.isCancelled else { return }
      self?.apply(result, generation: currentGeneration)
    }
  }

  public func refresh() {
    guard let request else { return }
    generation &+= 1
    let currentGeneration = generation
    loadTask?.cancel()
    if case .fallback(let descriptor, _) = presentation {
      presentation = .fallback(descriptor, isLoading: true)
    }
    loadTask = Task { [weak self, provider] in
      let result = await provider.refresh(request)
      guard !Task.isCancelled else { return }
      self?.apply(result, generation: currentGeneration)
    }
  }

  public func cancel() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    request = nil
  }

  private func apply(_ result: WebsiteIconResult, generation: UInt64) {
    guard generation == self.generation else { return }
    presentation = result.presentation
  }

  private func receive(_ update: WebsiteIconUpdate) {
    guard let request,
      request.bindingID == update.bindingID,
      let currentOrigin = try? WebsiteOrigin(websiteURL: request.websiteURL),
      currentOrigin == update.origin
    else { return }
    presentation = update.result.presentation
  }
}

/// A small reusable renderer. It performs no I/O; callers own the presentation
/// model so cards can keep layout stable while asynchronous icons arrive.
public struct WebsiteIconView: View {
  private let presentation: WebsiteIconPresentation
  private let size: CGFloat
  private let palette: [Color]

  public init(
    presentation: WebsiteIconPresentation,
    size: CGFloat = 44,
    fallbackPalette: [Color]? = nil
  ) {
    self.presentation = presentation
    self.size = size
    if let fallbackPalette, !fallbackPalette.isEmpty {
      palette = fallbackPalette
    } else {
      palette = Self.defaultPalette
    }
  }

  public var body: some View {
    Group {
      switch presentation {
      case .image(let artifact, _, _):
        if let image = NSImage(data: artifact.pngData) {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
        } else {
          fallbackView(.generic, isLoading: false)
        }
      case .fallback(let descriptor, let isLoading):
        fallbackView(descriptor, isLoading: isLoading)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func fallbackView(
    _ descriptor: WebsiteIconFallbackDescriptor,
    isLoading: Bool
  ) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        .fill(palette[Int(descriptor.colorSeed) % palette.count])
      Text(descriptor.monogram)
        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .lineLimit(1)
      if isLoading {
        ProgressView()
          .controlSize(.mini)
          .tint(.white)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .padding(size * 0.04)
      }
    }
  }

  private static let defaultPalette: [Color] = [
    Color(red: 0.12, green: 0.48, blue: 0.96),
    Color(red: 0.38, green: 0.32, blue: 0.91),
    Color(red: 0.68, green: 0.25, blue: 0.84),
    Color(red: 0.89, green: 0.25, blue: 0.48),
    Color(red: 0.94, green: 0.42, blue: 0.16),
    Color(red: 0.84, green: 0.61, blue: 0.08),
    Color(red: 0.16, green: 0.63, blue: 0.36),
    Color(red: 0.08, green: 0.62, blue: 0.61),
    Color(red: 0.08, green: 0.55, blue: 0.76),
    Color(red: 0.20, green: 0.42, blue: 0.78),
    Color(red: 0.44, green: 0.45, blue: 0.55),
    Color(red: 0.33, green: 0.52, blue: 0.48),
  ]
}
