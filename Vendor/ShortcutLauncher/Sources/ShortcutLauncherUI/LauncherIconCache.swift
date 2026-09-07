import AppKit
import Foundation

/// Small in-memory icon cache shared by the grid and application results.
/// Nothing is persisted, and the bounded count prevents a long-running host
/// from retaining every application icon it has ever displayed.
@MainActor
final class LauncherIconCache {
  static let shared = LauncherIconCache()

  private let cache = NSCache<NSURL, NSImage>()

  private init() {
    cache.countLimit = 64
  }

  func icon(for url: URL) -> NSImage {
    let key = url.standardizedFileURL as NSURL
    if let cached = cache.object(forKey: key) { return cached }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    cache.setObject(icon, forKey: key)
    return icon
  }
}
