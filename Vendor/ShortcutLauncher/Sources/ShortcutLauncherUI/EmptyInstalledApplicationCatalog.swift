import Foundation

/// Side-effect-free catalog for low-level injected module construction.
/// Production host convenience initialization supplies the real shared index;
/// tests and second hosts can opt in to filesystem discovery explicitly.
public struct EmptyInstalledApplicationCatalog: InstalledApplicationCataloging, Sendable {
  public init() {}

  public func applications(forceRefresh: Bool) async -> [ApplicationDescriptor] { [] }
  public func search(query: String, limit: Int) async -> [ApplicationDescriptor] { [] }
  public func prewarm(forceRefresh: Bool) async -> [ApplicationDescriptor] { [] }
  public func invalidate() async {}
}
