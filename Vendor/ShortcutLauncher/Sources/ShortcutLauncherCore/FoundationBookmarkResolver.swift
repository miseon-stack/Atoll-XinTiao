import Foundation

public struct FoundationBookmarkResolver: BookmarkResolving {
  public init() {}

  public func makeBookmark(for url: URL) throws -> Data {
    do {
      return try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      throw LauncherError.bookmarkCreationFailed(error.localizedDescription)
    }
  }

  public func resolve(_ bookmarkData: Data) throws -> ResolvedBookmark {
    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      return ResolvedBookmark(url: url, isStale: isStale)
    } catch {
      throw LauncherError.bookmarkResolveFailed(error.localizedDescription)
    }
  }
}
