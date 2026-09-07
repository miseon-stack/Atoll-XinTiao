import CoreGraphics
import Foundation
import ImageIO
import ShortcutLauncherCore
import UniformTypeIdentifiers
import XCTest

@testable import ShortcutLauncherUI

final class WebsiteIconResourceServiceTests: XCTestCase {
  override func tearDown() {
    WebsiteIconFixtureURLProtocol.reset()
    super.tearDown()
  }

  func testResourceLoaderRequestsOnlyOriginWithoutCredentialsOrTrackingHeaders() async throws {
    let recorder = WebsiteIconRequestRecorder()
    WebsiteIconFixtureURLProtocol.setHandler { request in
      recorder.record(request)
      return .response(
        statusCode: 200,
        mimeType: "text/html",
        headers: [:],
        data: Data("<head></head>".utf8)
      )
    }
    let loader = makeFixtureResourceLoader()
    let origin = try WebsiteOrigin("https://fixture.test/private/path?q=secret#fragment")

    _ = try await loader.loadOriginHTML(origin)

    let request = try XCTUnwrap(recorder.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://fixture.test/")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept"))
  }

  func testResourceLoaderRejectsOversizedAndWrongMIMEFixtures() async throws {
    WebsiteIconFixtureURLProtocol.setHandler { _ in
      .response(
        statusCode: 200,
        mimeType: "image/png",
        headers: ["Content-Length": "100"],
        data: Data(repeating: 1, count: 100)
      )
    }
    let tinyPolicy = WebsiteIconFetchPolicy(maximumImageBytes: 16)
    let oversizedLoader = makeFixtureResourceLoader(policy: tinyPolicy)
    let origin = try WebsiteOrigin("https://fixture.test")

    do {
      _ = try await oversizedLoader.loadIcon(
        at: try XCTUnwrap(URL(string: "https://fixture.test/favicon.ico")),
        for: origin,
        explicitlyDeclared: false
      )
      XCTFail("Expected responseTooLarge")
    } catch {
      XCTAssertEqual(error as? WebsiteResourceLoaderError, .responseTooLarge)
    }

    WebsiteIconFixtureURLProtocol.setHandler { _ in
      .response(
        statusCode: 200,
        mimeType: "text/html",
        headers: ["Content-Length": "100"],
        data: Data(repeating: 1, count: 100)
      )
    }
    let tinyHTMLPolicy = WebsiteIconFetchPolicy(maximumHTMLBytes: 16)
    let oversizedHTMLLoader = makeFixtureResourceLoader(policy: tinyHTMLPolicy)
    do {
      _ = try await oversizedHTMLLoader.loadOriginHTML(origin)
      XCTFail("Expected responseTooLarge")
    } catch {
      XCTAssertEqual(error as? WebsiteResourceLoaderError, .responseTooLarge)
    }

    WebsiteIconFixtureURLProtocol.setHandler { _ in
      .response(
        statusCode: 200,
        mimeType: "text/html",
        headers: [:],
        data: Data("not an icon".utf8)
      )
    }
    let wrongMIMELoader = makeFixtureResourceLoader()
    do {
      _ = try await wrongMIMELoader.loadIcon(
        at: try XCTUnwrap(URL(string: "https://fixture.test/favicon.ico")),
        for: origin,
        explicitlyDeclared: false
      )
      XCTFail("Expected unacceptableMIMEType")
    } catch {
      XCTAssertEqual(error as? WebsiteResourceLoaderError, .unacceptableMIMEType)
    }
  }

  func testRedirectPolicyEnforcesHopLimitAndSafetyOnEveryHop() throws {
    let origin = try WebsiteOrigin("https://fixture.test/private")
    let checker = AllowFixtureWebsiteURLSafetyChecker()
    let allowedURL = try XCTUnwrap(URL(string: "https://assets.fixture.test/icon.png"))

    XCTAssertNil(
      WebsiteRedirectPolicy.rejection(
        redirectCount: 3,
        maximumRedirects: 3,
        nextURL: allowedURL,
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: origin.rootURL,
        safetyChecker: checker
      ))
    XCTAssertEqual(
      WebsiteRedirectPolicy.rejection(
        redirectCount: 4,
        maximumRedirects: 3,
        nextURL: allowedURL,
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: origin.rootURL,
        safetyChecker: checker
      ),
      .tooManyRedirects
    )
    XCTAssertEqual(
      WebsiteRedirectPolicy.rejection(
        redirectCount: 1,
        maximumRedirects: 3,
        nextURL: URL(string: "https://blocked.invalid/icon.png"),
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: origin.rootURL,
        safetyChecker: checker
      ),
      .unsafeURL
    )
  }

  func testServiceCoalescesSameOriginAndPublishesDownloadedUpdate() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let png = try makeServicePNG()
    let loader = FixtureWebsiteResourceLoader(
      html: "<head><link rel='icon' type='image/png' href='/brand.png'></head>",
      imageData: png,
      delayNanoseconds: 40_000_000
    )
    let policy = WebsiteIconFetchPolicy(totalTimeout: 1)
    let service = fixture.makeService(policy: policy, loader: loader)
    let stream = await service.updates()
    let updateTask = Task { await stream.first(where: { _ in true }) }
    let url = try XCTUnwrap(URL(string: "https://fixture.test/private?q=secret"))
    let firstRequest = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "first"),
      websiteURL: url,
      reason: .newBinding
    )
    let secondRequest = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "second"),
      websiteURL: url,
      reason: .newBinding
    )

    async let first = service.icon(for: firstRequest)
    async let second = service.icon(for: secondRequest)
    let results = await [first, second]

    XCTAssertTrue(
      results.allSatisfy {
        if case .downloaded = $0 { return true }
        return false
      })
    XCTAssertEqual(loader.htmlRequestCount, 1)
    XCTAssertEqual(loader.iconRequestCount, 1)
    XCTAssertEqual(loader.requestedOriginURLs, ["https://fixture.test/"])
    let update = await updateTask.value
    XCTAssertNotNil(update)
    await service.cancelAll()
  }

  func testPassiveAndDisabledModesNeverStartNetwork() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let loader = FixtureWebsiteResourceLoader(html: "<head></head>", imageData: Data())
    let service = fixture.makeService(loader: loader, online: false)
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "web"),
      websiteURL: try XCTUnwrap(URL(string: "https://fixture.test/private")),
      reason: .newBinding
    )

    let disabled = await service.icon(for: request)
    assertFallback(disabled)
    XCTAssertEqual(loader.totalRequestCount, 0)

    await service.setOnlineFetchingEnabled(true)
    let passive = await service.icon(
      for: WebsiteIconRequest(
        bindingID: request.bindingID,
        websiteURL: request.websiteURL,
        reason: .passiveDisplay
      ))
    assertFallback(passive)
    XCTAssertEqual(loader.totalRequestCount, 0)
  }

  func testNegativeCachePreventsRepeatedFetchAndDiskCacheSurvivesOfflineRestart() async throws {
    let negativeFixture = try WebsiteIconServiceFixture()
    defer { negativeFixture.remove() }
    let failingLoader = FixtureWebsiteResourceLoader(
      html: "",
      imageData: Data(),
      failure: .networkFailure
    )
    let negativeService = negativeFixture.makeService(loader: failingLoader)
    let negativeRequest = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "negative"),
      websiteURL: try XCTUnwrap(URL(string: "https://missing.test/path")),
      reason: .newBinding
    )
    assertFallback(await negativeService.icon(for: negativeRequest))
    let firstCount = failingLoader.totalRequestCount
    XCTAssertGreaterThan(firstCount, 0)
    assertFallback(await negativeService.icon(for: negativeRequest))
    XCTAssertEqual(failingLoader.totalRequestCount, firstCount)

    let cachedFixture = try WebsiteIconServiceFixture()
    defer { cachedFixture.remove() }
    let png = try makeServicePNG()
    let successfulLoader = FixtureWebsiteResourceLoader(
      html: "<head><link rel='icon' href='/favicon.png' type='image/png'></head>",
      imageData: png
    )
    let policy = WebsiteIconFetchPolicy()
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "cached"),
      websiteURL: try XCTUnwrap(URL(string: "https://cached.test/private")),
      reason: .newBinding
    )
    let onlineService = cachedFixture.makeService(policy: policy, loader: successfulLoader)
    assertDownloaded(await onlineService.icon(for: request))

    let offlineLoader = FixtureWebsiteResourceLoader(html: "", imageData: Data())
    let offlineService = cachedFixture.makeService(
      policy: policy,
      loader: offlineLoader,
      online: false
    )
    let offlineResult = await offlineService.icon(for: request)
    if case .cache(_, let isStale) = offlineResult {
      XCTAssertFalse(isStale)
    } else {
      XCTFail("Expected disk cache hit, got \(offlineResult)")
    }
    XCTAssertEqual(offlineLoader.totalRequestCount, 0)
  }

  func testGlobalNetworkConcurrencyNeverExceedsFrozenLimit() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let png = try makeServicePNG()
    let loader = FixtureWebsiteResourceLoader(
      html: "<head><link rel='icon' href='/icon.png' type='image/png'></head>",
      imageData: png,
      delayNanoseconds: 25_000_000
    )
    let policy = WebsiteIconFetchPolicy(
      totalTimeout: 2,
      maximumConcurrentNetworkRequests: 3
    )
    let service = fixture.makeService(policy: policy, loader: loader)

    await withTaskGroup(of: WebsiteIconResult.self) { group in
      for index in 0..<9 {
        group.addTask {
          await service.icon(
            for: WebsiteIconRequest(
              bindingID: BindingID(rawValue: "binding-\(index)"),
              websiteURL: URL(string: "https://site-\(index).test/private")!,
              reason: .newBinding
            ))
        }
      }
      for await result in group { assertDownloaded(result) }
    }

    XCTAssertLessThanOrEqual(loader.maximumObservedConcurrency, 3)
  }

  func testServiceCustomIconOverridesNetworkAndCanRollbackRemoval() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let png = try makeServicePNG()
    let loader = FixtureWebsiteResourceLoader(html: "", imageData: Data())
    let policy = WebsiteIconFetchPolicy()
    let service = fixture.makeService(policy: policy, loader: loader)
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "custom"),
      websiteURL: URL(string: "https://custom.test/")!,
      reason: .newBinding
    )

    _ = try await service.storeCustomIcon(imageData: png, for: request)
    let custom = await service.icon(for: request)
    if case .custom = custom {} else { XCTFail("Expected custom icon") }
    XCTAssertEqual(loader.totalRequestCount, 0)

    let optionalRemoval = try await service.removeCustomIcon(for: request)
    let removal = try XCTUnwrap(optionalRemoval)
    assertFallback(
      await service.icon(
        for: WebsiteIconRequest(
          bindingID: request.bindingID,
          websiteURL: request.websiteURL,
          reason: .passiveDisplay
        )))
    await service.rollbackCustomIconMutation(removal, for: request)
    let restored = await service.icon(for: request)
    if case .custom = restored {} else { XCTFail("Expected restored custom icon") }
  }

  func testCustomIconWinsWhenAutomaticFetchCompletesLater() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let png = try makeServicePNG()
    let loader = FixtureWebsiteResourceLoader(
      html: "<head><link rel='icon' href='/icon.png'></head>",
      imageData: png,
      delayNanoseconds: 80_000_000
    )
    let service = fixture.makeService(
      policy: WebsiteIconFetchPolicy(totalTimeout: 1),
      loader: loader
    )
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "custom-race"),
      websiteURL: try XCTUnwrap(URL(string: "https://custom-race.test/path")),
      reason: .newBinding
    )
    let automaticFetch = Task { await service.icon(for: request) }
    try await Task.sleep(nanoseconds: 20_000_000)

    _ = try await service.storeCustomIcon(imageData: png, for: request)
    let result = await automaticFetch.value

    if case .custom = result {
    } else {
      XCTFail("Expected custom icon to retain presentation priority, got \(result)")
    }
  }

  func testWholeDiscoveryPipelineHonorsSingleTotalTimeout() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let loader = FixtureWebsiteResourceLoader(
      html: "<head></head>",
      imageData: Data(),
      delayNanoseconds: 500_000_000
    )
    let policy = WebsiteIconFetchPolicy(totalTimeout: 0.05)
    let service = fixture.makeService(policy: policy, loader: loader)
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "timeout"),
      websiteURL: URL(string: "https://timeout.test/private")!,
      reason: .newBinding
    )
    let startedAt = Date()

    let result = await service.icon(for: request)

    assertFallback(result)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.3)
  }

  func testServiceLimitsDiscoveredCandidatesAndIconDownloads() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let links = (0..<20).map { index in
      "<link rel='icon' type='image/png' href='/icon-\(index).png'>"
    }.joined()
    let loader = FixtureWebsiteResourceLoader(
      html: "<head>\(links)</head>",
      imageData: Data("invalid image".utf8)
    )
    let policy = WebsiteIconFetchPolicy(
      maximumDiscoveredCandidates: 8,
      maximumDownloadedCandidates: 3
    )
    let service = fixture.makeService(policy: policy, loader: loader)
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "candidate-limits"),
      websiteURL: try XCTUnwrap(URL(string: "https://limits.test/path")),
      reason: .newBinding
    )

    assertFallback(await service.icon(for: request))

    XCTAssertEqual(loader.htmlRequestCount, 1)
    XCTAssertEqual(loader.iconRequestCount, 3)
    XCTAssertEqual(
      FaviconLinkParser().candidates(
        in: Data("<head>\(links)</head>".utf8),
        documentURL: request.websiteURL,
        limit: policy.maximumDiscoveredCandidates
      ).count,
      8
    )
  }

  func testDisablingOnlineFetchingRejectsLateNetworkResult() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let png = try makeServicePNG()
    let loader = FixtureWebsiteResourceLoader(
      html: "<head><link rel='icon' href='/icon.png'></head>",
      imageData: png,
      delayNanoseconds: 200_000_000
    )
    let policy = WebsiteIconFetchPolicy(totalTimeout: 1)
    let service = fixture.makeService(policy: policy, loader: loader)
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "cancel-late-result"),
      websiteURL: try XCTUnwrap(URL(string: "https://cancel.test/private")),
      reason: .newBinding
    )
    let task = Task { await service.icon(for: request) }
    try await Task.sleep(nanoseconds: 20_000_000)

    await service.setOnlineFetchingEnabled(false)
    let result = await task.value

    assertFallback(result)
    XCTAssertGreaterThan(loader.totalRequestCount, 0)
    let cache = WebsiteIconDiskCache(directoryURL: fixture.cache, policy: policy)
    let cacheResult = await cache.lookup(
      try WebsiteOrigin(websiteURL: request.websiteURL),
      now: Date()
    )
    XCTAssertEqual(cacheResult, .miss)
  }

  func testFailedRefreshKeepsVerifiedStaleCache() async throws {
    let fixture = try WebsiteIconServiceFixture()
    defer { fixture.remove() }
    let png = try makeServicePNG()
    let policy = WebsiteIconFetchPolicy(successTTL: 1)
    let epoch = Date(timeIntervalSince1970: 1_000)
    let currentDate = epoch.addingTimeInterval(2)
    let cache = WebsiteIconDiskCache(directoryURL: fixture.cache, policy: policy)
    let origin = try WebsiteOrigin("https://stale.test/private")
    let artifact = try WebsiteIconImageDecoder(policy: policy).decodeAndNormalize(png)
    await cache.store(artifact, for: origin, now: epoch)
    let loader = FixtureWebsiteResourceLoader(
      html: "",
      imageData: Data(),
      failure: .networkFailure
    )
    let customStore = CustomWebsiteIconStore(
      directoryURL: fixture.custom,
      policy: policy
    )
    let service = WebsiteIconService(
      cacheDirectoryURL: fixture.cache,
      customIconsDirectoryURL: fixture.custom,
      policy: policy,
      resourceLoader: loader,
      cache: cache,
      customIconStore: customStore,
      now: { currentDate }
    )
    let request = WebsiteIconRequest(
      bindingID: BindingID(rawValue: "stale"),
      websiteURL: origin.rootURL,
      reason: .userRefresh
    )

    let result = await service.refresh(request)

    if case .cache(let cachedArtifact, let isStale) = result {
      XCTAssertEqual(cachedArtifact, artifact)
      XCTAssertTrue(isStale)
    } else {
      XCTFail("Expected stale verified cache, got \(result)")
    }
  }

  private func makeFixtureResourceLoader(
    policy: WebsiteIconFetchPolicy = .production
  ) -> WebsiteResourceLoader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WebsiteIconFixtureURLProtocol.self]
    return WebsiteResourceLoader(
      policy: policy,
      sessionConfiguration: configuration,
      safetyChecker: AllowFixtureWebsiteURLSafetyChecker()
    )
  }

  private func makeServicePNG() throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: 32,
        height: 32,
        bitsPerComponent: 8,
        bytesPerRow: 32 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
      ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

private func assertFallback(
  _ result: WebsiteIconResult,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  if case .fallback = result { return }
  XCTFail("Expected fallback, got \(result)", file: file, line: line)
}

private func assertDownloaded(
  _ result: WebsiteIconResult,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  if case .downloaded = result { return }
  XCTFail("Expected downloaded icon, got \(result)", file: file, line: line)
}

private struct AllowFixtureWebsiteURLSafetyChecker: WebsiteURLSafetyChecking {
  func allows(
    _ url: URL,
    initialOrigin: WebsiteOrigin,
    resourceKind: WebsiteResourceKind,
    redirectSource: URL?
  ) -> Bool {
    guard let destination = try? WebsiteOrigin(websiteURL: url) else { return false }
    return destination.scheme == "https" && destination.host.hasSuffix(".test")
  }
}

private enum WebsiteIconFixtureResponse {
  case response(statusCode: Int, mimeType: String?, headers: [String: String], data: Data)
  case failure(URLError.Code)
}

private final class WebsiteIconFixtureURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var handler:
    (@Sendable (URLRequest) -> WebsiteIconFixtureResponse)?
  private static let handlerLock = NSLock()

  static func setHandler(
    _ handler: @escaping @Sendable (URLRequest) -> WebsiteIconFixtureResponse
  ) {
    handlerLock.lock()
    self.handler = handler
    handlerLock.unlock()
  }

  static func reset() {
    handlerLock.lock()
    handler = nil
    handlerLock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.handlerLock.lock()
    let handler = Self.handler
    Self.handlerLock.unlock()
    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    switch handler(request) {
    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .response(let statusCode, let mimeType, var headers, let data):
      if let mimeType { headers["Content-Type"] = mimeType }
      guard let url = request.url,
        let response = HTTPURLResponse(
          url: url,
          statusCode: statusCode,
          httpVersion: "HTTP/1.1",
          headerFields: headers
        )
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

private final class WebsiteIconRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [URLRequest] = []

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func record(_ request: URLRequest) {
    lock.lock()
    storage.append(request)
    lock.unlock()
  }
}

private final class FixtureWebsiteResourceLoader: WebsiteResourceLoading, @unchecked Sendable {
  private let html: String
  private let imageData: Data
  private let delayNanoseconds: UInt64
  private let failure: WebsiteResourceLoaderError?
  private let lock = NSLock()
  private var htmlCount = 0
  private var iconCount = 0
  private var activeCount = 0
  private var maximumActiveCount = 0
  private var origins: [String] = []

  init(
    html: String,
    imageData: Data,
    delayNanoseconds: UInt64 = 0,
    failure: WebsiteResourceLoaderError? = nil
  ) {
    self.html = html
    self.imageData = imageData
    self.delayNanoseconds = delayNanoseconds
    self.failure = failure
  }

  var htmlRequestCount: Int { locked { htmlCount } }
  var iconRequestCount: Int { locked { iconCount } }
  var totalRequestCount: Int { locked { htmlCount + iconCount } }
  var maximumObservedConcurrency: Int { locked { maximumActiveCount } }
  var requestedOriginURLs: [String] { locked { origins } }

  func loadOriginHTML(_ origin: WebsiteOrigin) async throws -> WebsiteResourceResponse {
    begin(isHTML: true, origin: origin)
    defer { end() }
    try await pauseIfNeeded()
    if let failure { throw failure }
    return WebsiteResourceResponse(
      data: Data(html.utf8),
      mimeType: "text/html",
      finalURL: origin.rootURL,
      statusCode: 200
    )
  }

  func loadIcon(
    at url: URL,
    for origin: WebsiteOrigin,
    explicitlyDeclared: Bool
  ) async throws -> WebsiteResourceResponse {
    begin(isHTML: false, origin: nil)
    defer { end() }
    try await pauseIfNeeded()
    if let failure { throw failure }
    return WebsiteResourceResponse(
      data: imageData,
      mimeType: "image/png",
      finalURL: url,
      statusCode: 200
    )
  }

  func cancelAll() {}

  private func begin(isHTML: Bool, origin: WebsiteOrigin?) {
    lock.lock()
    if isHTML {
      htmlCount += 1
      if let origin { origins.append(origin.rootURL.absoluteString) }
    } else {
      iconCount += 1
    }
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    lock.unlock()
  }

  private func end() {
    lock.lock()
    activeCount -= 1
    lock.unlock()
  }

  private func pauseIfNeeded() async throws {
    if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private final class WebsiteIconServiceFixture {
  let root: URL
  let cache: URL
  let custom: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WebsiteIconServiceTests-\(UUID().uuidString)",
      isDirectory: true
    )
    cache = root.appendingPathComponent("cache", isDirectory: true)
    custom = root.appendingPathComponent("custom", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func makeService(
    policy: WebsiteIconFetchPolicy = .production,
    loader: any WebsiteResourceLoading,
    online: Bool = true
  ) -> WebsiteIconService {
    WebsiteIconService(
      cacheDirectoryURL: cache,
      customIconsDirectoryURL: custom,
      policy: policy,
      resourceLoader: loader,
      onlineFetchingEnabled: online
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
