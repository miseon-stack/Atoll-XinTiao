import AppKit
import ShortcutLauncherCore

@MainActor
public final class NSWorkspaceTargetOpener: WorkspaceOpening {
  public init() {}

  public func open(target: LaunchTarget, resolvedURL: URL) async throws {
    switch target.kind {
    case .application:
      try await openApplication(at: resolvedURL)
    case .file, .folder, .web:
      guard NSWorkspace.shared.open(resolvedURL) else {
        throw LauncherError.targetOpenFailed(target.displayName)
      }
    }
  }

  private func openApplication(at url: URL) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(
        at: url,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(
            throwing: LauncherError.targetOpenFailed(
              error.localizedDescription
            )
          )
        } else {
          continuation.resume()
        }
      }
    }
  }
}
