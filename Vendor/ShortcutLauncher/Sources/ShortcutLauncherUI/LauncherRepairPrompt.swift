import ShortcutLauncherCore

/// Privacy-safe, in-process feedback for a failed global launch.
public struct LauncherRepairPrompt: Equatable, Identifiable, Sendable {
  public var id: BindingID { bindingID }
  public let bindingID: BindingID
  public let displayName: String
  public let targetKind: LaunchTargetKind
  public let errorCode: ExecutionFailureCode

  public init(
    bindingID: BindingID,
    displayName: String,
    targetKind: LaunchTargetKind,
    errorCode: ExecutionFailureCode
  ) {
    self.bindingID = bindingID.hostSafeProjection
    self.displayName = displayName
    self.targetKind = targetKind
    self.errorCode = errorCode
  }
}

/// Optional host boundary for presenting a transient HUD, banner, or other
/// notification-free failure surface. The payload is already privacy-filtered.
@MainActor
public protocol LauncherFeedbackPresenting: AnyObject {
  func present(_ prompt: LauncherRepairPrompt)
  func dismiss(bindingID: BindingID)
}

@MainActor
public final class NoopLauncherFeedbackPresenter: LauncherFeedbackPresenting {
  public init() {}
  public func present(_ prompt: LauncherRepairPrompt) {}
  public func dismiss(bindingID: BindingID) {}
}
