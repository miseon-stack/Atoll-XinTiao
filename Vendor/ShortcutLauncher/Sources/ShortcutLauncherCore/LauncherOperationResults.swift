/// Stable, presentation-independent validation categories returned to hosts.
public enum LauncherIssueCode: String, Sendable, Equatable {
  case invalidHotkey
  case duplicateHotkey
  case panelHotkeyConflict
  case invalidTarget
  case invalidConfiguration
}

/// A structured validation issue containing stable identities only.
public struct LauncherIssue: Sendable, Equatable {
  public var code: LauncherIssueCode
  public var bindingID: BindingID?
  public var relatedBindingID: BindingID?
  public var combination: HotkeyDefinition?

  public init(
    code: LauncherIssueCode,
    bindingID: BindingID? = nil,
    relatedBindingID: BindingID? = nil,
    combination: HotkeyDefinition? = nil
  ) {
    self.code = code
    self.bindingID = bindingID?.hostSafeProjection
    self.relatedBindingID = relatedBindingID?.hostSafeProjection
    self.combination = combination
  }
}

public enum LauncherPersistenceFailureCode: String, Sendable, Equatable {
  case readFailed
  case writeFailed
  case recoveryIncomplete
  case rollbackFailed
}

public enum LauncherCommitRejectionReason: String, Sendable, Equatable {
  case moduleUnavailable
  case moduleStopping
  case transactionInProgress
  case staleRevision
  case noChanges
}

/// The public result of a configuration transaction. It never contains target
/// paths, URLs, OSStatus values or platform registration handles.
public enum LauncherCommitResult: Sendable, Equatable {
  case committed(configurationRevision: UInt64, enabled: [BindingID])
  case validationFailed([LauncherIssue])
  case registrationFailed(bindingID: BindingID?, combination: HotkeyDefinition)
  case persistenceFailed(code: LauncherPersistenceFailureCode)
  case rejected(reason: LauncherCommitRejectionReason)
}

/// The result of retrying exactly one persisted direct shortcut.
public enum HotkeyRetryResult: Sendable, Equatable {
  case enabled(BindingID)
  case stillConflicted(BindingID)
  case notConfigured(BindingID)
  case moduleUnavailable
}

public enum ExecutionFailureCode: String, Sendable, Equatable {
  case moduleUnavailable
  case noBinding
  case targetResolutionFailed
  case openRejected
  case cancelled
  case unknown
}

/// The public result of an execution request. Diagnostics may retain private
/// platform details separately, but this value remains safe for UI and hosts.
public enum ExecutionResult: Sendable, Equatable {
  case accepted(BindingID)
  case targetUnavailable(BindingID)
  case failed(BindingID, code: ExecutionFailureCode)
}
