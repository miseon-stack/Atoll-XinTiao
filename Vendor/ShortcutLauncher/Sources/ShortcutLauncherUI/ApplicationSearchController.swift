import Combine
import Foundation

/// A privacy-safe reason for an application-index query failure.
public enum ApplicationSearchFailure: String, Equatable, Sendable {
  case unavailable

  public var message: String {
    switch self {
    case .unavailable:
      "暂时无法列出应用，请重试或选择其他应用。"
    }
  }
}

/// An immutable view of one application query generation.
public struct ApplicationSearchSnapshot: Equatable, Sendable {
  public let generation: UInt64
  public let rawQuery: String
  public let normalizedQuery: String
  public let candidates: [ApplicationDescriptor]
  public let selectedID: String?
  public let isLoading: Bool
  public let failure: ApplicationSearchFailure?

  public init(
    generation: UInt64 = 0,
    rawQuery: String = "",
    normalizedQuery: String = "",
    candidates: [ApplicationDescriptor] = [],
    selectedID: String? = nil,
    isLoading: Bool = false,
    failure: ApplicationSearchFailure? = nil
  ) {
    self.generation = generation
    self.rawQuery = rawQuery
    self.normalizedQuery = normalizedQuery
    self.candidates = candidates
    self.selectedID = selectedID
    self.isLoading = isLoading
    self.failure = failure
  }

  public var selectedCandidate: ApplicationDescriptor? {
    guard !isLoading, failure == nil, let selectedID else { return nil }
    return candidates.first { $0.id == selectedID }
  }
}

public enum ApplicationSearchNavigationDirection: Equatable, Sendable {
  case previous
  case next
}

/// Boundary behavior is explicit so embedding hosts can choose either familiar
/// clamped menus or a wrapping command-palette interaction.
public enum ApplicationSearchNavigationPolicy: Equatable, Sendable {
  case clamp
  case wrap
}

public enum ApplicationSearchKeyboardAction: Equatable, Sendable {
  case move(ApplicationSearchNavigationDirection)
  case submit
  case escape
}

/// The AppKit text adapter obtains this value from its field editor's marked range.
public struct ApplicationSearchInputContext: Equatable, Sendable {
  public let hasMarkedText: Bool

  public init(hasMarkedText: Bool = false) {
    self.hasMarkedText = hasMarkedText
  }
}

public enum ApplicationSearchKeyboardDecision: Equatable, Sendable {
  /// The input method owns Return, arrows and Esc while marked text is present.
  case passThroughToInputMethod
  case selectionChanged(id: String)
  case submit(ApplicationDescriptor)
  case dismiss
  case ignored
}

public typealias ApplicationSearchOperation =
  @Sendable (
    _ normalizedQuery: String,
    _ limit: Int
  ) async throws -> [ApplicationDescriptor]

public typealias ApplicationSearchSleeper = @Sendable (_ duration: Duration) async throws -> Void

public typealias ApplicationCatalogPrewarmOperation =
  @Sendable (
    _ forceRefresh: Bool
  ) async -> Void

/// Main-actor presentation state for deterministic, cancellable application search.
///
/// Directory traversal belongs to the injected catalog actor. This controller
/// only sequences UI generations, debounce, selection identity and key intent.
@MainActor
public final class ApplicationSearchController: ObservableObject {
  @Published public private(set) var snapshot = ApplicationSearchSnapshot()

  public let debounceDuration: Duration
  public let resultLimit: Int
  public let navigationPolicy: ApplicationSearchNavigationPolicy

  private let searchOperation: ApplicationSearchOperation
  private let sleeper: ApplicationSearchSleeper
  private let prewarmOperation: ApplicationCatalogPrewarmOperation?
  private var searchTask: Task<Void, Never>?
  private var prewarmTask: Task<Void, Never>?

  public init(
    debounceDuration: Duration = .milliseconds(80),
    resultLimit: Int = 8,
    navigationPolicy: ApplicationSearchNavigationPolicy = .clamp,
    searchOperation: @escaping ApplicationSearchOperation,
    sleeper: @escaping ApplicationSearchSleeper = { duration in
      try await ContinuousClock().sleep(for: duration)
    },
    prewarmOperation: ApplicationCatalogPrewarmOperation? = nil
  ) {
    self.debounceDuration = debounceDuration
    self.resultLimit = max(0, resultLimit)
    self.navigationPolicy = navigationPolicy
    self.searchOperation = searchOperation
    self.sleeper = sleeper
    self.prewarmOperation = prewarmOperation
  }

  public convenience init(
    catalog: any InstalledApplicationCataloging = InstalledApplicationCatalog.shared,
    debounceDuration: Duration = .milliseconds(80),
    resultLimit: Int = 8,
    navigationPolicy: ApplicationSearchNavigationPolicy = .clamp,
    sleeper: @escaping ApplicationSearchSleeper = { duration in
      try await ContinuousClock().sleep(for: duration)
    }
  ) {
    self.init(
      debounceDuration: debounceDuration,
      resultLimit: resultLimit,
      navigationPolicy: navigationPolicy,
      searchOperation: { query, limit in
        await catalog.search(query: query, limit: limit)
      },
      sleeper: sleeper,
      prewarmOperation: { forceRefresh in
        _ = await catalog.prewarm(forceRefresh: forceRefresh)
      }
    )
  }

  deinit {
    searchTask?.cancel()
    prewarmTask?.cancel()
  }

  /// Starts a low-priority catalog warm-up. It never changes query presentation
  /// state and repeated calls are coalesced by cancelling this lightweight waiter;
  /// the catalog actor itself still guarantees one serial cache mutation.
  public func prewarmApplications(forceRefresh: Bool = false) {
    guard let prewarmOperation else { return }
    prewarmTask?.cancel()
    prewarmTask = Task(priority: .utility) {
      await prewarmOperation(forceRefresh)
    }
  }

  /// Begins a fresh generation. Old candidates and selection immediately lose
  /// submission eligibility before the debounce or index lookup starts.
  public func updateQuery(_ rawQuery: String) {
    startSearch(
      rawQuery: rawQuery,
      preferredSelectionID: nil
    )
  }

  /// Rebuilds the current result list, optionally restoring the same selected
  /// identity if that application still exists after index refresh/reordering.
  public func refresh(preservingSelection: Bool = true) {
    startSearch(
      rawQuery: snapshot.rawQuery,
      preferredSelectionID: preservingSelection ? snapshot.selectedID : nil
    )
  }

  /// Invalidates outstanding work. Late providers cannot publish because this
  /// operation advances the generation even when they ignore task cancellation.
  public func cancel(clearQuery: Bool = false) {
    searchTask?.cancel()
    searchTask = nil
    let nextGeneration = advancedGeneration()
    let rawQuery = clearQuery ? "" : snapshot.rawQuery
    snapshot = ApplicationSearchSnapshot(
      generation: nextGeneration,
      rawQuery: rawQuery,
      normalizedQuery: Self.normalizeQuery(rawQuery)
    )
  }

  public func stop() {
    cancel(clearQuery: true)
    prewarmTask?.cancel()
    prewarmTask = nil
  }

  /// Selects only a candidate from the currently visible generation. Passing a
  /// captured generation makes stale mouse rows as safe as keyboard submission.
  @discardableResult
  public func selectCandidate(id: String, generation: UInt64? = nil) -> Bool {
    if let generation, generation != snapshot.generation { return false }
    guard !snapshot.isLoading,
      snapshot.failure == nil,
      snapshot.candidates.contains(where: { $0.id == id })
    else {
      return false
    }
    setSelectedID(id)
    return true
  }

  /// Moves by stable ID, never by an index retained across result replacement.
  @discardableResult
  public func moveSelection(_ direction: ApplicationSearchNavigationDirection) -> String? {
    guard !snapshot.isLoading, snapshot.failure == nil, !snapshot.candidates.isEmpty else {
      return nil
    }

    let candidates = snapshot.candidates
    let targetIndex: Int
    if let selectedID = snapshot.selectedID,
      let currentIndex = candidates.firstIndex(where: { $0.id == selectedID })
    {
      switch (direction, navigationPolicy) {
      case (.previous, .clamp):
        targetIndex = max(candidates.startIndex, currentIndex - 1)
      case (.next, .clamp):
        targetIndex = min(candidates.index(before: candidates.endIndex), currentIndex + 1)
      case (.previous, .wrap):
        targetIndex =
          currentIndex == candidates.startIndex
          ? candidates.index(before: candidates.endIndex)
          : currentIndex - 1
      case (.next, .wrap):
        targetIndex =
          currentIndex == candidates.index(before: candidates.endIndex)
          ? candidates.startIndex
          : currentIndex + 1
      }
    } else {
      targetIndex =
        direction == .next
        ? candidates.startIndex
        : candidates.index(before: candidates.endIndex)
    }

    let selectedID = candidates[targetIndex].id
    setSelectedID(selectedID)
    return selectedID
  }

  /// Resolves a click or Return against both captured generation and candidate ID.
  /// A result that has disappeared or belonged to an older query is rejected.
  public func candidateForSubmission(
    id: String,
    generation: UInt64,
    inputContext: ApplicationSearchInputContext = ApplicationSearchInputContext()
  ) -> ApplicationDescriptor? {
    guard !inputContext.hasMarkedText,
      generation == snapshot.generation,
      !snapshot.isLoading,
      snapshot.failure == nil,
      snapshot.selectedID == id
    else {
      return nil
    }
    return snapshot.candidates.first { $0.id == id }
  }

  /// Purely testable interpretation of the field editor's keyboard commands.
  @discardableResult
  public func handleKeyboardAction(
    _ action: ApplicationSearchKeyboardAction,
    inputContext: ApplicationSearchInputContext = ApplicationSearchInputContext()
  ) -> ApplicationSearchKeyboardDecision {
    guard !inputContext.hasMarkedText else { return .passThroughToInputMethod }

    switch action {
    case .move(let direction):
      guard let selectedID = moveSelection(direction) else { return .ignored }
      return .selectionChanged(id: selectedID)
    case .submit:
      guard let selectedID = snapshot.selectedID,
        let candidate = candidateForSubmission(
          id: selectedID,
          generation: snapshot.generation,
          inputContext: inputContext
        )
      else {
        return .ignored
      }
      return .submit(candidate)
    case .escape:
      return .dismiss
    }
  }

  public static func normalizeQuery(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .lowercased()
  }

  private func startSearch(rawQuery: String, preferredSelectionID: String?) {
    searchTask?.cancel()
    let generation = advancedGeneration()
    let normalizedQuery = Self.normalizeQuery(rawQuery)
    snapshot = ApplicationSearchSnapshot(
      generation: generation,
      rawQuery: rawQuery,
      normalizedQuery: normalizedQuery,
      isLoading: true
    )

    let debounceDuration = debounceDuration
    let limit = resultLimit
    let searchOperation = searchOperation
    let sleeper = sleeper
    searchTask = Task { [weak self] in
      do {
        try await sleeper(debounceDuration)
        try Task.checkCancellation()
        let candidates = try await searchOperation(normalizedQuery, limit)
        try Task.checkCancellation()
        self?.publish(
          candidates: candidates,
          generation: generation,
          normalizedQuery: normalizedQuery,
          preferredSelectionID: preferredSelectionID
        )
      } catch is CancellationError {
        // Query replacement and explicit cancellation are expected control flow.
      } catch {
        guard !Task.isCancelled else { return }
        self?.publishFailure(generation: generation, normalizedQuery: normalizedQuery)
      }
    }
  }

  private func publish(
    candidates: [ApplicationDescriptor],
    generation: UInt64,
    normalizedQuery: String,
    preferredSelectionID: String?
  ) {
    guard generation == snapshot.generation,
      normalizedQuery == snapshot.normalizedQuery,
      snapshot.isLoading
    else {
      return
    }

    var seenIDs = Set<String>()
    let uniqueCandidates = candidates.filter { seenIDs.insert($0.id).inserted }
    let selectedID =
      preferredSelectionID.flatMap { preferredID in
        uniqueCandidates.contains(where: { $0.id == preferredID }) ? preferredID : nil
      } ?? uniqueCandidates.first?.id
    snapshot = ApplicationSearchSnapshot(
      generation: generation,
      rawQuery: snapshot.rawQuery,
      normalizedQuery: normalizedQuery,
      candidates: uniqueCandidates,
      selectedID: selectedID
    )
  }

  private func publishFailure(generation: UInt64, normalizedQuery: String) {
    guard generation == snapshot.generation,
      normalizedQuery == snapshot.normalizedQuery,
      snapshot.isLoading
    else {
      return
    }
    snapshot = ApplicationSearchSnapshot(
      generation: generation,
      rawQuery: snapshot.rawQuery,
      normalizedQuery: normalizedQuery,
      failure: .unavailable
    )
  }

  private func setSelectedID(_ selectedID: String?) {
    snapshot = ApplicationSearchSnapshot(
      generation: snapshot.generation,
      rawQuery: snapshot.rawQuery,
      normalizedQuery: snapshot.normalizedQuery,
      candidates: snapshot.candidates,
      selectedID: selectedID,
      isLoading: snapshot.isLoading,
      failure: snapshot.failure
    )
  }

  private func advancedGeneration() -> UInt64 {
    var generation = snapshot.generation &+ 1
    if generation == 0 { generation = 1 }
    return generation
  }
}
