import Foundation

/// Stable lifecycle values exposed to an embedding host.
///
/// The state deliberately carries no underlying error text. Recoverable
/// details are represented by `LauncherRuntimeIssueCode` instead, keeping the
/// host surface independent from localized messages and platform diagnostics.
public enum LauncherLifecycleState: String, Sendable, Equatable, CaseIterable {
  case stopped
  case starting
  case running
  case stopping
  case unavailable
}

/// Non-sensitive, stable issue categories that may be surfaced by a host.
public enum LauncherRuntimeIssueCode: String, Sendable, Equatable, CaseIterable {
  case panelHotkeyUnavailable
  case directHotkeyConflict
  case targetUnavailable
  case configurationRecovered
  case registrationRecoveryIncomplete
  case configurationRollbackFailed
  case moduleUnavailable
}

/// A privacy-safe host projection of one launcher slot.
///
/// This type intentionally does not retain a `LaunchTarget`, URL, bookmark, or
/// configuration storage location. `displayName` is filtered at construction
/// time so an accidentally supplied URL or path is replaced by the generic
/// localized target-kind label.
public struct BindingRuntimeSummary: Sendable, Equatable, Identifiable {
  public var id: UInt16 { slotKeyCode }
  public let bindingID: BindingID?
  public let slotKeyCode: UInt16
  public let targetKind: LaunchTargetKind?
  public let displayName: String?
  public let runtimeState: BindingRuntimeState

  public init(
    bindingID: BindingID?,
    slotKeyCode: UInt16,
    targetKind: LaunchTargetKind?,
    displayName: String?,
    runtimeState: BindingRuntimeState
  ) {
    self.bindingID = bindingID?.hostSafeProjection
    self.slotKeyCode = slotKeyCode
    self.targetKind = targetKind
    self.displayName = Self.makePrivacySafeDisplayName(
      displayName,
      targetKind: targetKind
    )
    self.runtimeState = runtimeState
  }

  /// Converts the richer in-process presentation into the narrower public
  /// contract without exposing target locations.
  public init(presentation: BindingPresentation) {
    self.init(
      bindingID: presentation.bindingID,
      slotKeyCode: presentation.slotKeyCode,
      targetKind: presentation.targetKind,
      displayName: presentation.displayName,
      runtimeState: presentation.runtimeState
    )
  }

  private static func makePrivacySafeDisplayName(
    _ candidate: String?,
    targetKind: LaunchTargetKind?
  ) -> String? {
    guard targetKind != nil else { return nil }
    guard let candidate else { return targetKind?.displayName }

    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return targetKind?.displayName }

    let visibleScalars = trimmed.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
    }
    let cleaned = String(String.UnicodeScalarView(visibleScalars))
    guard !cleaned.isEmpty else { return targetKind?.displayName }

    let lowercased = cleaned.lowercased()
    let hasURIScheme: Bool = {
      guard let colon = cleaned.firstIndex(of: ":"), colon != cleaned.startIndex else {
        return false
      }
      let scheme = cleaned[..<colon]
      guard let first = scheme.unicodeScalars.first,
        CharacterSet.letters.contains(first)
      else { return false }
      return scheme.dropFirst().unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)
      }
    }()
    let resemblesURL = lowercased.contains("://")
      || lowercased.hasPrefix("www.")
      || lowercased.hasPrefix("file:")
    let resemblesPath = cleaned.contains("/")
      || cleaned.contains("\\")
      || lowercased.hasPrefix("~")
    let containsURLDetails = cleaned.contains("?") || cleaned.contains("#")
    guard !hasURIScheme, !resemblesURL, !resemblesPath, !containsURLDetails else {
      return targetKind?.displayName
    }

    return String(cleaned.prefix(80))
  }
}

/// Immutable state intended for embedding hosts and diagnostics UI.
///
/// The snapshot contains no persisted configuration object by design. In
/// particular, it cannot expose configuration paths, target URLs, or bookmark
/// data through its public storage.
public struct LauncherRuntimeSnapshot: Sendable, Equatable {
  public let lifecycleState: LauncherLifecycleState
  public let configurationRevision: UInt64
  public let panelHotkey: HotkeyDefinition
  public let directHotkeysPaused: Bool
  public let bindings: [BindingRuntimeSummary]
  public let issueCodes: [LauncherRuntimeIssueCode]

  public init(
    lifecycleState: LauncherLifecycleState,
    configurationRevision: UInt64,
    panelHotkey: HotkeyDefinition,
    directHotkeysPaused: Bool,
    bindings: [BindingRuntimeSummary],
    issueCodes: [LauncherRuntimeIssueCode] = []
  ) {
    self.lifecycleState = lifecycleState
    self.configurationRevision = configurationRevision
    self.panelHotkey = panelHotkey
    self.directHotkeysPaused = directHotkeysPaused
    self.bindings = bindings.sorted { lhs, rhs in
      if lhs.slotKeyCode != rhs.slotKeyCode {
        return lhs.slotKeyCode < rhs.slotKeyCode
      }
      return (lhs.bindingID?.rawValue ?? "") < (rhs.bindingID?.rawValue ?? "")
    }
    self.issueCodes = Array(Set(issueCodes)).sorted { $0.rawValue < $1.rawValue }
  }
}

/// Optimistic, revision-aware request to publish a complete configuration
/// candidate through the launcher's transactional commit path.
public struct LauncherCommitRequest: Sendable, Equatable {
  public let expectedConfigurationRevision: UInt64
  public let candidateConfiguration: LauncherConfiguration

  public init(
    expectedConfigurationRevision: UInt64,
    candidateConfiguration: LauncherConfiguration
  ) {
    self.expectedConfigurationRevision = expectedConfigurationRevision
    self.candidateConfiguration = candidateConfiguration
  }
}

/// Extended public contract for a second host or future product integration.
///
/// `executeWithResult` intentionally has a distinct name from the legacy
/// `ShortcutLauncherModuleProtocol.execute(bindingID:source:) -> Void` method.
/// Swift cannot overload methods solely by return type, so this preserves the
/// Phase 2 compatibility surface while adding a structured result.
@MainActor
public protocol ShortcutLauncherControlling: AnyObject {
  var snapshot: LauncherRuntimeSnapshot { get }

  func start() async throws
  func stop() async
  func presentPanel()
  func dismissPanel()

  func commit(_ request: LauncherCommitRequest) async -> LauncherCommitResult
  func retryDirectHotkey(bindingID: BindingID) async -> HotkeyRetryResult
  func executeWithResult(
    bindingID: BindingID,
    source: TriggerSource
  ) async -> ExecutionResult
}
