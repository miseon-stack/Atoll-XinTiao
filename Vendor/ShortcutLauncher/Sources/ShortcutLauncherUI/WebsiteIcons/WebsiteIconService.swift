import Foundation
import ShortcutLauncherCore

public actor WebsiteIconService: WebsiteIconProviding, WebsiteIconUpdateStreaming {
  private struct MemoryEntry {
    enum Value {
      case positive(WebsiteIconArtifact)
      case negative
    }

    let value: Value
    let expiresAt: Date
    var lastAccess: UInt64
  }

  private struct InFlight {
    let token: UUID
    let lifecycleGeneration: UInt64
    let task: Task<WebsiteIconFetchOutcome, Never>
    var bindingIDs: Set<BindingID>
  }

  private let policy: WebsiteIconFetchPolicy
  private let loader: any WebsiteResourceLoading
  private let parser: FaviconLinkParser
  private let decoder: any WebsiteIconImageDecoding
  private let cache: any WebsiteIconCacheStoring
  private let customStore: any CustomWebsiteIconStoring
  public nonisolated let customIconManager: (any CustomWebsiteIconManaging)?
  private let permitPool: WebsiteNetworkPermitPool
  private let now: @Sendable () -> Date

  private var onlineFetchingEnabled: Bool
  private var lifecycleGeneration: UInt64 = 0
  private var accessCounter: UInt64 = 0
  private var memory: [String: MemoryEntry] = [:]
  private var inFlight: [String: InFlight] = [:]
  private var updateContinuations: [UUID: AsyncStream<WebsiteIconUpdate>.Continuation] = [:]

  /// Host-neutral defaults. Embedding products should normally inject their own
  /// Caches and Application Support directories.
  public init(
    cacheDirectoryURL: URL = WebsiteIconService.defaultCacheDirectoryURL(),
    customIconsDirectoryURL: URL = WebsiteIconService.defaultCustomIconsDirectoryURL(),
    policy: WebsiteIconFetchPolicy = .production,
    resourceLoader: (any WebsiteResourceLoading)? = nil,
    imageDecoder: (any WebsiteIconImageDecoding)? = nil,
    cache: (any WebsiteIconCacheStoring)? = nil,
    customIconStore: (any CustomWebsiteIconManaging)? = nil,
    onlineFetchingEnabled: Bool = true,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let resolvedDecoder = imageDecoder ?? WebsiteIconImageDecoder(policy: policy)
    let resolvedCustomStore =
      customIconStore
      ?? CustomWebsiteIconStore(
        directoryURL: customIconsDirectoryURL,
        policy: policy,
        decoder: resolvedDecoder
      )
    self.policy = policy
    loader = resourceLoader ?? WebsiteResourceLoader(policy: policy)
    parser = FaviconLinkParser()
    decoder = resolvedDecoder
    self.cache =
      cache
      ?? WebsiteIconDiskCache(
        directoryURL: cacheDirectoryURL,
        policy: policy
      )
    self.customStore = resolvedCustomStore
    customIconManager = resolvedCustomStore
    permitPool = WebsiteNetworkPermitPool(limit: policy.maximumConcurrentNetworkRequests)
    self.onlineFetchingEnabled = onlineFetchingEnabled
    self.now = now
  }

  public func icon(for request: WebsiteIconRequest) async -> WebsiteIconResult {
    guard let origin = try? WebsiteOrigin(websiteURL: request.websiteURL) else {
      return .fallback(.generic)
    }
    if let custom = await customStore.artifact(for: request.bindingID, origin: origin) {
      return .custom(custom)
    }

    let currentDate = now()
    if let cached = memoryLookup(origin, now: currentDate) {
      switch cached {
      case .positive(let artifact, let isStale, _):
        if isStale, shouldStartNetwork(for: request.reason) {
          startBackgroundRefresh(request: request, origin: origin)
        }
        return .cache(artifact, isStale: isStale)
      case .negative:
        return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
      case .miss:
        break
      }
    }

    switch await cache.lookup(origin, now: currentDate) {
    case .positive(let artifact, let isStale, let expiresAt):
      insertMemory(artifact, for: origin, expiresAt: expiresAt)
      if isStale, shouldStartNetwork(for: request.reason) {
        startBackgroundRefresh(request: request, origin: origin)
      }
      return .cache(artifact, isStale: isStale)
    case .negative(let expiresAt):
      insertNegativeMemory(for: origin, expiresAt: expiresAt)
      return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
    case .miss:
      break
    }

    guard shouldStartNetwork(for: request.reason) else {
      return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
    }
    return await fetch(request: request, origin: origin)
  }

  public func refresh(_ request: WebsiteIconRequest) async -> WebsiteIconResult {
    guard let origin = try? WebsiteOrigin(websiteURL: request.websiteURL) else {
      return .fallback(.generic)
    }
    if let custom = await customStore.artifact(for: request.bindingID, origin: origin) {
      return .custom(custom)
    }
    guard onlineFetchingEnabled else {
      return await cachedOrFallback(origin: origin)
    }
    return await fetch(request: request, origin: origin)
  }

  public func setOnlineFetchingEnabled(_ enabled: Bool) {
    guard onlineFetchingEnabled != enabled else { return }
    onlineFetchingEnabled = enabled
    if !enabled { cancelOutstandingRequests() }
  }

  public func isOnlineFetchingEnabled() -> Bool {
    onlineFetchingEnabled
  }

  public func clearAutomaticCache() async {
    cancelOutstandingRequests()
    memory.removeAll()
    await cache.removeAll()
  }

  public func cancelAll() {
    cancelOutstandingRequests()
    for continuation in updateContinuations.values { continuation.finish() }
    updateContinuations.removeAll()
  }

  public func updates() -> AsyncStream<WebsiteIconUpdate> {
    let identifier = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
      updateContinuations[identifier] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeUpdateContinuation(identifier) }
      }
    }
  }

  @discardableResult
  public func storeCustomIcon(
    imageData: Data,
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation? {
    guard let origin = try? WebsiteOrigin(websiteURL: request.websiteURL),
      let customIconManager
    else { return nil }
    let mutation = try await customIconManager.store(
      imageData: imageData,
      for: request.bindingID,
      origin: origin
    )
    if let artifact = await customIconManager.artifact(for: request.bindingID, origin: origin) {
      publish(
        WebsiteIconUpdate(
          bindingID: request.bindingID,
          origin: origin,
          result: .custom(artifact)
        ))
    }
    return mutation
  }

  @discardableResult
  public func removeCustomIcon(
    for request: WebsiteIconRequest
  ) async throws -> CustomWebsiteIconMutation? {
    guard let origin = try? WebsiteOrigin(websiteURL: request.websiteURL),
      let customIconManager
    else { return nil }
    let mutation = try await customIconManager.remove(for: request.bindingID, origin: origin)
    let result = await cachedOrFallback(origin: origin)
    publish(WebsiteIconUpdate(bindingID: request.bindingID, origin: origin, result: result))
    return mutation
  }

  public func rollbackCustomIconMutation(
    _ mutation: CustomWebsiteIconMutation,
    for request: WebsiteIconRequest
  ) async {
    guard let origin = try? WebsiteOrigin(websiteURL: request.websiteURL),
      let customIconManager
    else { return }
    await customIconManager.rollback(mutation)
    let result: WebsiteIconResult
    if let artifact = await customIconManager.artifact(for: request.bindingID, origin: origin) {
      result = .custom(artifact)
    } else {
      result = await cachedOrFallback(origin: origin)
    }
    publish(WebsiteIconUpdate(bindingID: request.bindingID, origin: origin, result: result))
  }

  public func finalizeCustomIconMutation(_ mutation: CustomWebsiteIconMutation) async {
    await customIconManager?.finalize(mutation)
  }

  public nonisolated static func defaultCacheDirectoryURL(
    fileManager: FileManager = .default
  ) -> URL {
    let root =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return
      root
      .appendingPathComponent("ShortcutLauncher", isDirectory: true)
      .appendingPathComponent("WebsiteIcons-Automatic-v1", isDirectory: true)
  }

  public nonisolated static func defaultCustomIconsDirectoryURL(
    fileManager: FileManager = .default
  ) -> URL {
    let root =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return
      root
      .appendingPathComponent("ShortcutLauncher", isDirectory: true)
      .appendingPathComponent("WebsiteIcons-Custom-v1", isDirectory: true)
  }

  private func fetch(
    request: WebsiteIconRequest,
    origin: WebsiteOrigin
  ) async -> WebsiteIconResult {
    let key = origin.cacheKey
    if var existing = inFlight[key] {
      existing.bindingIDs.insert(request.bindingID)
      inFlight[key] = existing
      let outcome = await existing.task.value
      let result = await finalizeFetch(
        outcome,
        key: key,
        token: existing.token,
        generation: existing.lifecycleGeneration,
        origin: origin
      )
      return await preferringCustomIcon(result, for: request.bindingID, origin: origin)
    }

    let token = UUID()
    let generation = lifecycleGeneration
    let policy = self.policy
    let loader = self.loader
    let parser = self.parser
    let decoder = self.decoder
    let permitPool = self.permitPool
    let task = Task {
      await Self.performFetchWithTimeout(
        origin: origin,
        policy: policy,
        loader: loader,
        parser: parser,
        decoder: decoder,
        permitPool: permitPool
      )
    }
    inFlight[key] = InFlight(
      token: token,
      lifecycleGeneration: generation,
      task: task,
      bindingIDs: [request.bindingID]
    )
    let outcome = await task.value
    let result = await finalizeFetch(
      outcome,
      key: key,
      token: token,
      generation: generation,
      origin: origin
    )
    return await preferringCustomIcon(result, for: request.bindingID, origin: origin)
  }

  private func finalizeFetch(
    _ outcome: WebsiteIconFetchOutcome,
    key: String,
    token: UUID,
    generation: UInt64,
    origin: WebsiteOrigin
  ) async -> WebsiteIconResult {
    guard lifecycleGeneration == generation else {
      return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
    }
    guard let current = inFlight[key], current.token == token,
      current.lifecycleGeneration == generation
    else { return result(from: outcome, origin: origin) }
    inFlight.removeValue(forKey: key)
    let currentDate = now()

    switch outcome {
    case .success(let artifact):
      insertMemory(
        artifact,
        for: origin,
        expiresAt: currentDate.addingTimeInterval(policy.successTTL)
      )
      await cache.store(artifact, for: origin, now: currentDate)
      let result = WebsiteIconResult.downloaded(artifact)
      for bindingID in current.bindingIDs {
        let updateResult = await preferringCustomIcon(result, for: bindingID, origin: origin)
        publish(WebsiteIconUpdate(bindingID: bindingID, origin: origin, result: updateResult))
      }
      return result
    case .failure:
      if case .positive(let artifact)? = memory[origin.cacheKey]?.value,
        let entry = memory[origin.cacheKey]
      {
        // stale-while-revalidate: keep the last verified image when refresh
        // fails rather than replacing it with a negative entry.
        return .cache(artifact, isStale: entry.expiresAt <= currentDate)
      } else if case .positive(let artifact, let isStale, let expiresAt) = await cache.lookup(
        origin,
        now: currentDate
      ) {
        // The disk cache may contain a stale verified icon not yet in memory.
        insertMemory(artifact, for: origin, expiresAt: expiresAt)
        return .cache(artifact, isStale: isStale)
      } else {
        insertNegativeMemory(for: origin, now: currentDate)
        await cache.storeNegative(for: origin, now: currentDate)
      }
      return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
    case .cancelled:
      return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
    }
  }

  private func cachedOrFallback(origin: WebsiteOrigin) async -> WebsiteIconResult {
    let currentDate = now()
    if let lookup = memoryLookup(origin, now: currentDate) {
      switch lookup {
      case .positive(let artifact, let isStale, _): return .cache(artifact, isStale: isStale)
      case .negative, .miss: break
      }
    }
    switch await cache.lookup(origin, now: currentDate) {
    case .positive(let artifact, let isStale, let expiresAt):
      insertMemory(artifact, for: origin, expiresAt: expiresAt)
      return .cache(artifact, isStale: isStale)
    case .negative, .miss:
      return .fallback(WebsiteIconFallbackDescriptor(origin: origin))
    }
  }

  private func shouldStartNetwork(for reason: WebsiteIconRequest.Reason) -> Bool {
    onlineFetchingEnabled && reason != .passiveDisplay
  }

  private func startBackgroundRefresh(request: WebsiteIconRequest, origin: WebsiteOrigin) {
    guard inFlight[origin.cacheKey] == nil else {
      inFlight[origin.cacheKey]?.bindingIDs.insert(request.bindingID)
      return
    }
    Task { [weak self] in
      _ = await self?.fetch(request: request, origin: origin)
    }
  }

  private func memoryLookup(
    _ origin: WebsiteOrigin,
    now currentDate: Date
  ) -> WebsiteIconCacheLookup? {
    guard var entry = memory[origin.cacheKey] else { return nil }
    accessCounter &+= 1
    entry.lastAccess = accessCounter
    memory[origin.cacheKey] = entry
    switch entry.value {
    case .positive(let artifact):
      return .positive(
        artifact,
        isStale: entry.expiresAt <= currentDate,
        expiresAt: entry.expiresAt
      )
    case .negative:
      if entry.expiresAt <= currentDate {
        memory.removeValue(forKey: origin.cacheKey)
        return .miss
      }
      return .negative(expiresAt: entry.expiresAt)
    }
  }

  private func insertMemory(
    _ artifact: WebsiteIconArtifact,
    for origin: WebsiteOrigin,
    expiresAt: Date
  ) {
    accessCounter &+= 1
    memory[origin.cacheKey] = MemoryEntry(
      value: .positive(artifact),
      expiresAt: expiresAt,
      lastAccess: accessCounter
    )
    pruneMemory()
  }

  private func insertNegativeMemory(for origin: WebsiteOrigin, now currentDate: Date) {
    insertNegativeMemory(
      for: origin,
      expiresAt: currentDate.addingTimeInterval(policy.negativeCacheTTL)
    )
  }

  private func insertNegativeMemory(for origin: WebsiteOrigin, expiresAt: Date) {
    accessCounter &+= 1
    memory[origin.cacheKey] = MemoryEntry(
      value: .negative,
      expiresAt: expiresAt,
      lastAccess: accessCounter
    )
    pruneMemory()
  }

  private func pruneMemory() {
    while memory.count > policy.maximumMemoryOrigins,
      let oldest = memory.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
    {
      memory.removeValue(forKey: oldest)
    }
  }

  private func cancelOutstandingRequests() {
    lifecycleGeneration &+= 1
    let tasks = inFlight.values.map(\.task)
    inFlight.removeAll()
    for task in tasks { task.cancel() }
    loader.cancelAll()
  }

  private func publish(_ update: WebsiteIconUpdate) {
    for continuation in updateContinuations.values { continuation.yield(update) }
  }

  private func removeUpdateContinuation(_ identifier: UUID) {
    updateContinuations.removeValue(forKey: identifier)
  }

  private func result(
    from outcome: WebsiteIconFetchOutcome,
    origin: WebsiteOrigin
  ) -> WebsiteIconResult {
    switch outcome {
    case .success(let artifact): .downloaded(artifact)
    case .failure, .cancelled: .fallback(WebsiteIconFallbackDescriptor(origin: origin))
    }
  }

  private func preferringCustomIcon(
    _ result: WebsiteIconResult,
    for bindingID: BindingID,
    origin: WebsiteOrigin
  ) async -> WebsiteIconResult {
    if let artifact = await customStore.artifact(for: bindingID, origin: origin) {
      return .custom(artifact)
    }
    return result
  }

  private nonisolated static func performFetchWithTimeout(
    origin: WebsiteOrigin,
    policy: WebsiteIconFetchPolicy,
    loader: any WebsiteResourceLoading,
    parser: FaviconLinkParser,
    decoder: any WebsiteIconImageDecoding,
    permitPool: WebsiteNetworkPermitPool
  ) async -> WebsiteIconFetchOutcome {
    await withTaskGroup(of: WebsiteIconFetchOutcome.self) { group in
      group.addTask {
        await performFetch(
          origin: origin,
          policy: policy,
          loader: loader,
          parser: parser,
          decoder: decoder,
          permitPool: permitPool
        )
      }
      group.addTask {
        do {
          try await Task.sleep(for: .seconds(policy.totalTimeout))
          return .failure
        } catch {
          return .cancelled
        }
      }
      let first = await group.next() ?? .failure
      group.cancelAll()
      return first
    }
  }

  private nonisolated static func performFetch(
    origin: WebsiteOrigin,
    policy: WebsiteIconFetchPolicy,
    loader: any WebsiteResourceLoading,
    parser: FaviconLinkParser,
    decoder: any WebsiteIconImageDecoding,
    permitPool: WebsiteNetworkPermitPool
  ) async -> WebsiteIconFetchOutcome {
    guard !Task.isCancelled else { return .cancelled }
    var candidates: [(url: URL, explicitlyDeclared: Bool)] = []
    do {
      let response = try await permitPool.perform {
        try await loader.loadOriginHTML(origin)
      }
      if response.data.count <= policy.maximumHTMLBytes {
        candidates = parser.candidates(
          in: response.data,
          documentURL: response.finalURL,
          limit: policy.maximumDiscoveredCandidates
        ).map { ($0.url, true) }
      }
    } catch {
      if Task.isCancelled { return .cancelled }
    }

    let fallbackURL = origin.rootURL.appendingPathComponent("favicon.ico", isDirectory: false)
    if !candidates.contains(where: { $0.url == fallbackURL }) {
      if candidates.count == policy.maximumDiscoveredCandidates { candidates.removeLast() }
      candidates.append((fallbackURL, false))
    }

    for candidate in candidates.prefix(policy.maximumDownloadedCandidates) {
      guard !Task.isCancelled else { return .cancelled }
      do {
        let response = try await permitPool.perform {
          try await loader.loadIcon(
            at: candidate.url,
            for: origin,
            explicitlyDeclared: candidate.explicitlyDeclared
          )
        }
        return .success(try decoder.decodeAndNormalize(response.data))
      } catch {
        if Task.isCancelled { return .cancelled }
      }
    }
    return .failure
  }
}

private enum WebsiteIconFetchOutcome: Sendable {
  case success(WebsiteIconArtifact)
  case failure
  case cancelled
}

private actor WebsiteNetworkPermitPool {
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(limit: Int) {
    available = max(1, limit)
  }

  public func perform<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    await acquire()
    guard !Task.isCancelled else {
      release()
      throw CancellationError()
    }
    defer { release() }
    return try await operation()
  }

  private func acquire() async {
    if available > 0 {
      available -= 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    if waiters.isEmpty {
      available += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}
