import XCTest

@testable import ShortcutLauncherUI

@MainActor
final class ApplicationSearchControllerTests: XCTestCase {
  func testDefaultDebounceIsExactlyEightyMillisecondsAndDelaysLookup() async {
    let sleeper = ControlledSearchSleeper()
    let recorder = SearchInvocationRecorder(result: [application("alpha", name: "Alpha")])
    let controller = ApplicationSearchController(
      searchOperation: { query, limit in
        await recorder.search(query: query, limit: limit)
      },
      sleeper: { duration in
        await sleeper.sleep(for: duration)
      }
    )

    controller.updateQuery("Alpha")
    await waitUntil { await sleeper.requestCount == 1 }

    let requestedDurations = await sleeper.requestedDurations
    let requestCountBeforeDebounce = await recorder.requestCount
    XCTAssertEqual(controller.debounceDuration, .milliseconds(80))
    XCTAssertEqual(requestedDurations, [.milliseconds(80)])
    XCTAssertEqual(requestCountBeforeDebounce, 0)
    XCTAssertTrue(controller.snapshot.isLoading)
    XCTAssertTrue(controller.snapshot.candidates.isEmpty)

    await sleeper.resumeAll()
    await waitUntil { !controller.snapshot.isLoading }

    let queries = await recorder.queries
    XCTAssertEqual(queries, ["alpha"])
    XCTAssertEqual(controller.snapshot.candidates.map(\.id), ["alpha"])
    XCTAssertEqual(controller.snapshot.selectedID, "alpha")
  }

  func testNewGenerationImmediatelyInvalidatesOldResultsAndRejectsLateProvider() async {
    let provider = ControlledApplicationSearch()
    let controller = controller(provider: provider)

    controller.updateQuery("old")
    let oldGeneration = controller.snapshot.generation
    await waitUntil { await provider.hasRequest(for: "old") }

    controller.updateQuery("new")
    let newGeneration = controller.snapshot.generation
    XCTAssertGreaterThan(newGeneration, oldGeneration)
    XCTAssertTrue(controller.snapshot.isLoading)
    XCTAssertTrue(controller.snapshot.candidates.isEmpty)
    XCTAssertNil(controller.snapshot.selectedID)
    await waitUntil { await provider.hasRequest(for: "new") }

    await provider.complete(
      query: "new",
      with: [application("new", name: "New Application")]
    )
    await waitUntil { controller.snapshot.selectedID == "new" }

    await provider.complete(
      query: "old",
      with: [application("old", name: "Old Application")]
    )
    await allowPendingActorWork()

    XCTAssertEqual(controller.snapshot.generation, newGeneration)
    XCTAssertEqual(controller.snapshot.candidates.map(\.id), ["new"])
    XCTAssertEqual(controller.snapshot.selectedID, "new")
    XCTAssertNil(controller.candidateForSubmission(id: "old", generation: oldGeneration))
  }

  func testCancelAdvancesGenerationAndRejectsProviderThatIgnoresCancellation() async {
    let provider = ControlledApplicationSearch()
    let controller = controller(provider: provider)

    controller.updateQuery("late")
    let searchingGeneration = controller.snapshot.generation
    await waitUntil { await provider.hasRequest(for: "late") }

    controller.cancel()
    let cancelledGeneration = controller.snapshot.generation
    XCTAssertGreaterThan(cancelledGeneration, searchingGeneration)
    XCTAssertFalse(controller.snapshot.isLoading)
    XCTAssertTrue(controller.snapshot.candidates.isEmpty)

    await provider.complete(
      query: "late",
      with: [application("late", name: "Late Application")]
    )
    await allowPendingActorWork()

    XCTAssertEqual(controller.snapshot.generation, cancelledGeneration)
    XCTAssertTrue(controller.snapshot.candidates.isEmpty)
    XCTAssertNil(controller.snapshot.selectedID)
  }

  func testRefreshRestoresStableSelectedIDAcrossResultReordering() async {
    let provider = SequencedApplicationSearch(results: [
      [application("a", name: "Alpha"), application("b", name: "Beta")],
      [application("b", name: "Beta"), application("a", name: "Alpha")],
    ])
    let controller = ApplicationSearchController(
      debounceDuration: .zero,
      searchOperation: { query, limit in
        await provider.search(query: query, limit: limit)
      },
      sleeper: { _ in }
    )

    controller.updateQuery("")
    await waitUntil { !controller.snapshot.isLoading }
    XCTAssertEqual(controller.snapshot.selectedID, "a")
    XCTAssertTrue(controller.selectCandidate(id: "b"))

    controller.refresh(preservingSelection: true)
    XCTAssertTrue(controller.snapshot.isLoading)
    XCTAssertNil(controller.snapshot.selectedID, "loading results must not remain submittable")
    await waitUntil { !controller.snapshot.isLoading }

    XCTAssertEqual(controller.snapshot.candidates.map(\.id), ["b", "a"])
    XCTAssertEqual(controller.snapshot.selectedID, "b")
  }

  func testClampedAndWrappedNavigationHaveExplicitBoundaryBehavior() async {
    let candidates = [
      application("a", name: "Alpha"),
      application("b", name: "Beta"),
      application("c", name: "Charlie"),
    ]
    let clamped = immediateController(candidates: candidates, navigationPolicy: .clamp)
    clamped.updateQuery("")
    await waitUntil { !clamped.snapshot.isLoading }

    XCTAssertEqual(clamped.moveSelection(.previous), "a")
    XCTAssertEqual(clamped.moveSelection(.next), "b")
    XCTAssertEqual(clamped.moveSelection(.next), "c")
    XCTAssertEqual(clamped.moveSelection(.next), "c")

    let wrapped = immediateController(candidates: candidates, navigationPolicy: .wrap)
    wrapped.updateQuery("")
    await waitUntil { !wrapped.snapshot.isLoading }

    XCTAssertEqual(wrapped.moveSelection(.previous), "c")
    XCTAssertEqual(wrapped.moveSelection(.next), "a")
  }

  func testMarkedTextPassesReturnArrowsAndEscapeToInputMethod() async {
    let candidate = application("wechat", name: "微信")
    let controller = immediateController(candidates: [candidate])
    controller.updateQuery("微信")
    await waitUntil { !controller.snapshot.isLoading }
    let markedText = ApplicationSearchInputContext(hasMarkedText: true)

    XCTAssertEqual(
      controller.handleKeyboardAction(.move(.next), inputContext: markedText),
      .passThroughToInputMethod
    )
    XCTAssertEqual(
      controller.handleKeyboardAction(.submit, inputContext: markedText),
      .passThroughToInputMethod
    )
    XCTAssertEqual(
      controller.handleKeyboardAction(.escape, inputContext: markedText),
      .passThroughToInputMethod
    )
    XCTAssertNil(
      controller.candidateForSubmission(
        id: candidate.id,
        generation: controller.snapshot.generation,
        inputContext: markedText
      )
    )
    XCTAssertEqual(controller.snapshot.selectedID, candidate.id)
  }

  func testKeyboardSubmitAndEscapeUseCurrentVisibleSelectionOnly() async {
    let alpha = application("alpha", name: "Alpha")
    let beta = application("beta", name: "Beta")
    let controller = immediateController(candidates: [alpha, beta])
    controller.updateQuery("app")
    await waitUntil { !controller.snapshot.isLoading }
    let generation = controller.snapshot.generation

    XCTAssertEqual(
      controller.handleKeyboardAction(.move(.next)),
      .selectionChanged(id: beta.id)
    )
    XCTAssertEqual(controller.handleKeyboardAction(.submit), .submit(beta))
    XCTAssertEqual(controller.handleKeyboardAction(.escape), .dismiss)
    XCTAssertNil(controller.candidateForSubmission(id: alpha.id, generation: generation))
    XCTAssertEqual(
      controller.candidateForSubmission(id: beta.id, generation: generation),
      beta
    )
  }

  func testFailureAndEmptyAreDistinctNonSubmittableStates() async {
    struct FixtureFailure: Error {}

    let failed = ApplicationSearchController(
      debounceDuration: .zero,
      searchOperation: { _, _ in throw FixtureFailure() },
      sleeper: { _ in }
    )
    failed.updateQuery("failure")
    await waitUntil { !failed.snapshot.isLoading }
    XCTAssertEqual(failed.snapshot.failure, .unavailable)
    XCTAssertTrue(failed.snapshot.candidates.isEmpty)
    XCTAssertEqual(failed.handleKeyboardAction(.submit), .ignored)

    let empty = immediateController(candidates: [])
    empty.updateQuery("empty")
    await waitUntil { !empty.snapshot.isLoading }
    XCTAssertNil(empty.snapshot.failure)
    XCTAssertTrue(empty.snapshot.candidates.isEmpty)
    XCTAssertEqual(empty.handleKeyboardAction(.move(.next)), .ignored)
  }

  func testQueryNormalizationIsStableAndProviderReceivesOnlyNormalizedValue() async {
    let recorder = SearchInvocationRecorder(result: [])
    let controller = ApplicationSearchController(
      debounceDuration: .zero,
      searchOperation: { query, limit in
        await recorder.search(query: query, limit: limit)
      },
      sleeper: { _ in }
    )

    controller.updateQuery("  ＣＡＦÉ\n App  ")
    await waitUntil { !controller.snapshot.isLoading }

    XCTAssertEqual(controller.snapshot.rawQuery, "  ＣＡＦÉ\n App  ")
    XCTAssertEqual(controller.snapshot.normalizedQuery, "cafe app")
    let queries = await recorder.queries
    XCTAssertEqual(queries, ["cafe app"])
  }

  func testDuplicateProviderIDsAreRemovedBeforeSelection() async {
    let first = application("same", name: "First")
    let duplicate = application("same", name: "Second")
    let controller = immediateController(candidates: [first, duplicate])

    controller.updateQuery("")
    await waitUntil { !controller.snapshot.isLoading }

    XCTAssertEqual(controller.snapshot.candidates, [first])
    XCTAssertEqual(controller.snapshot.selectedID, first.id)
  }

  private func controller(
    provider: ControlledApplicationSearch
  ) -> ApplicationSearchController {
    ApplicationSearchController(
      debounceDuration: .zero,
      searchOperation: { query, limit in
        await provider.search(query: query, limit: limit)
      },
      sleeper: { _ in }
    )
  }

  private func immediateController(
    candidates: [ApplicationDescriptor],
    navigationPolicy: ApplicationSearchNavigationPolicy = .clamp
  ) -> ApplicationSearchController {
    ApplicationSearchController(
      debounceDuration: .zero,
      navigationPolicy: navigationPolicy,
      searchOperation: { _, limit in Array(candidates.prefix(limit)) },
      sleeper: { _ in }
    )
  }

  private func application(_ id: String, name: String) -> ApplicationDescriptor {
    ApplicationDescriptor(
      id: id,
      displayName: name,
      bundleIdentifier: "fixture.\(id)",
      url: URL(fileURLWithPath: "/Fixture/\(id).app")
    )
  }

  private func waitUntil(
    attempts: Int = 2_000,
    _ condition: @escaping @MainActor () async -> Bool
  ) async {
    for _ in 0..<attempts {
      if await condition() { return }
      await Task.yield()
    }
    XCTFail("condition did not become true")
  }

  private func allowPendingActorWork() async {
    for _ in 0..<20 { await Task.yield() }
  }
}

private actor ControlledApplicationSearch {
  private var continuations: [String: [CheckedContinuation<[ApplicationDescriptor], Never>]] = [:]

  func search(query: String, limit: Int) async -> [ApplicationDescriptor] {
    let result = await withCheckedContinuation { continuation in
      continuations[query, default: []].append(continuation)
    }
    return Array(result.prefix(limit))
  }

  func hasRequest(for query: String) -> Bool {
    continuations[query]?.isEmpty == false
  }

  func complete(query: String, with result: [ApplicationDescriptor]) {
    guard var queued = continuations[query], !queued.isEmpty else { return }
    let continuation = queued.removeFirst()
    continuations[query] = queued
    continuation.resume(returning: result)
  }
}

private actor SequencedApplicationSearch {
  private var results: [[ApplicationDescriptor]]

  init(results: [[ApplicationDescriptor]]) {
    self.results = results
  }

  func search(query: String, limit: Int) -> [ApplicationDescriptor] {
    guard !results.isEmpty else { return [] }
    return Array(results.removeFirst().prefix(limit))
  }
}

private actor ControlledSearchSleeper {
  private var durations: [Duration] = []
  private var continuations: [CheckedContinuation<Void, Never>] = []

  var requestCount: Int { durations.count }
  var requestedDurations: [Duration] { durations }

  func sleep(for duration: Duration) async {
    durations.append(duration)
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func resumeAll() {
    let queued = continuations
    continuations.removeAll()
    for continuation in queued {
      continuation.resume()
    }
  }
}

private actor SearchInvocationRecorder {
  private(set) var queries: [String] = []
  private(set) var limits: [Int] = []
  private let result: [ApplicationDescriptor]

  init(result: [ApplicationDescriptor]) {
    self.result = result
  }

  var requestCount: Int { queries.count }

  func search(query: String, limit: Int) -> [ApplicationDescriptor] {
    queries.append(query)
    limits.append(limit)
    return Array(result.prefix(limit))
  }
}
