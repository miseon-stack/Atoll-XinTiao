import Foundation

public enum WebsiteResourceLoaderError: Error, Equatable, Sendable {
  case unsafeURL
  case invalidResponse
  case unacceptableStatus(Int)
  case unacceptableMIMEType
  case responseTooLarge
  case tooManyRedirects
  case authenticationRequired
  case cancelled
  case networkFailure
}

public struct WebsiteResourceResponse: Equatable, Sendable {
  public let data: Data
  public let mimeType: String?
  public let finalURL: URL
  public let statusCode: Int

  public init(data: Data, mimeType: String?, finalURL: URL, statusCode: Int) {
    self.data = data
    self.mimeType = mimeType
    self.finalURL = finalURL
    self.statusCode = statusCode
  }
}

public protocol WebsiteResourceLoading: Sendable {
  func loadOriginHTML(_ origin: WebsiteOrigin) async throws -> WebsiteResourceResponse
  func loadIcon(
    at url: URL,
    for origin: WebsiteOrigin,
    explicitlyDeclared: Bool
  ) async throws -> WebsiteResourceResponse
  func cancelAll()
}

/// Pure redirect validation kept separate from URLSession delegate plumbing so
/// every hop and the frozen redirect budget can be tested without a network.
enum WebsiteRedirectPolicy {
  static func rejection(
    redirectCount: Int,
    maximumRedirects: Int,
    nextURL: URL?,
    initialOrigin: WebsiteOrigin,
    resourceKind: WebsiteResourceKind,
    redirectSource: URL?,
    safetyChecker: any WebsiteURLSafetyChecking
  ) -> WebsiteResourceLoaderError? {
    guard redirectCount <= maximumRedirects else { return .tooManyRedirects }
    guard let nextURL,
      safetyChecker.allows(
        nextURL,
        initialOrigin: initialOrigin,
        resourceKind: resourceKind,
        redirectSource: redirectSource
      )
    else { return .unsafeURL }
    return nil
  }
}

/// A credential-free, cookie-free URLSession boundary with incremental byte
/// limits and redirect validation for every hop.
public final class WebsiteResourceLoader: WebsiteResourceLoading, @unchecked Sendable {
  private let policy: WebsiteIconFetchPolicy
  private let safetyChecker: any WebsiteURLSafetyChecking
  private let configurationBox: WebsiteSessionConfigurationBox
  private let lock = NSLock()
  private var runners: [UUID: BoundedWebsiteRequestRunner] = [:]

  public init(
    policy: WebsiteIconFetchPolicy = .production,
    sessionConfiguration: URLSessionConfiguration? = nil,
    safetyChecker: any WebsiteURLSafetyChecking = DefaultWebsiteURLSafetyChecker()
  ) {
    self.policy = policy
    self.safetyChecker = safetyChecker
    let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = policy.totalTimeout
    configuration.timeoutIntervalForResource = policy.totalTimeout
    configuration.httpMaximumConnectionsPerHost = policy.maximumConcurrentNetworkRequests
    configuration.httpAdditionalHeaders = [:]
    configurationBox = WebsiteSessionConfigurationBox(configuration)
  }

  public func loadOriginHTML(_ origin: WebsiteOrigin) async throws -> WebsiteResourceResponse {
    let response = try await load(
      url: origin.rootURL,
      origin: origin,
      resourceKind: .originHTML,
      maximumBytes: policy.maximumHTMLBytes,
      accept: "text/html,application/xhtml+xml;q=0.9"
    )
    guard WebsiteMIMEPolicy.acceptsHTML(response.mimeType, data: response.data) else {
      throw WebsiteResourceLoaderError.unacceptableMIMEType
    }
    return response
  }

  public func loadIcon(
    at url: URL,
    for origin: WebsiteOrigin,
    explicitlyDeclared: Bool
  ) async throws -> WebsiteResourceResponse {
    let response = try await load(
      url: url,
      origin: origin,
      resourceKind: explicitlyDeclared ? .declaredIcon : .fallbackIcon,
      maximumBytes: policy.maximumImageBytes,
      accept: "image/png,image/vnd.microsoft.icon,image/x-icon,image/jpeg,image/gif;q=0.9"
    )
    guard WebsiteMIMEPolicy.acceptsImage(response.mimeType, resourceURL: response.finalURL) else {
      throw WebsiteResourceLoaderError.unacceptableMIMEType
    }
    return response
  }

  public func cancelAll() {
    let active: [BoundedWebsiteRequestRunner] = withLock {
      let values = Array(runners.values)
      runners.removeAll()
      return values
    }
    for runner in active { runner.cancel() }
  }

  private func load(
    url: URL,
    origin: WebsiteOrigin,
    resourceKind: WebsiteResourceKind,
    maximumBytes: Int,
    accept: String
  ) async throws -> WebsiteResourceResponse {
    guard
      safetyChecker.allows(
        url,
        initialOrigin: origin,
        resourceKind: resourceKind,
        redirectSource: nil
      )
    else {
      throw WebsiteResourceLoaderError.unsafeURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = policy.totalTimeout
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(accept, forHTTPHeaderField: "Accept")

    let identifier = UUID()
    let runner = BoundedWebsiteRequestRunner(
      configuration: configurationBox.makeCopy(),
      request: request,
      maximumBytes: maximumBytes,
      maximumRedirects: policy.maximumRedirects,
      initialOrigin: origin,
      resourceKind: resourceKind,
      safetyChecker: safetyChecker
    )
    withLock { runners[identifier] = runner }
    defer { _ = withLock { runners.removeValue(forKey: identifier) } }
    return try await runner.load()
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private final class WebsiteSessionConfigurationBox: @unchecked Sendable {
  private let configuration: URLSessionConfiguration

  init(_ configuration: URLSessionConfiguration) {
    self.configuration = configuration
  }

  func makeCopy() -> URLSessionConfiguration {
    (configuration.copy() as? URLSessionConfiguration) ?? configuration
  }
}

private final class BoundedWebsiteRequestRunner: NSObject, URLSessionDataDelegate,
  URLSessionTaskDelegate, @unchecked Sendable
{
  private let configuration: URLSessionConfiguration
  private let request: URLRequest
  private let maximumBytes: Int
  private let maximumRedirects: Int
  private let initialOrigin: WebsiteOrigin
  private let resourceKind: WebsiteResourceKind
  private let safetyChecker: any WebsiteURLSafetyChecking
  private let lock = NSLock()

  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var response: HTTPURLResponse?
  private var receivedData = Data()
  private var redirectCount = 0
  private var continuation: CheckedContinuation<WebsiteResourceResponse, Error>?
  private var completed = false
  private var cancellationRequested = false

  init(
    configuration: URLSessionConfiguration,
    request: URLRequest,
    maximumBytes: Int,
    maximumRedirects: Int,
    initialOrigin: WebsiteOrigin,
    resourceKind: WebsiteResourceKind,
    safetyChecker: any WebsiteURLSafetyChecking
  ) {
    self.configuration = configuration
    self.request = request
    self.maximumBytes = maximumBytes
    self.maximumRedirects = maximumRedirects
    self.initialOrigin = initialOrigin
    self.resourceKind = resourceKind
    self.safetyChecker = safetyChecker
  }

  func load() async throws -> WebsiteResourceResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if cancellationRequested {
          lock.unlock()
          continuation.resume(throwing: WebsiteResourceLoaderError.cancelled)
          return
        }
        self.continuation = continuation
        let session = URLSession(
          configuration: configuration,
          delegate: self,
          delegateQueue: nil
        )
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() {
    lock.lock()
    cancellationRequested = true
    let task = task
    lock.unlock()
    task?.cancel()
    finish(.failure(WebsiteResourceLoaderError.cancelled))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    lock.lock()
    redirectCount += 1
    let count = redirectCount
    lock.unlock()

    if let rejection = WebsiteRedirectPolicy.rejection(
      redirectCount: count,
      maximumRedirects: maximumRedirects,
      nextURL: request.url,
      initialOrigin: initialOrigin,
      resourceKind: resourceKind,
      redirectSource: response.url,
      safetyChecker: safetyChecker
    ) {
      completionHandler(nil)
      finish(.failure(rejection))
      return
    }

    guard let nextURL = request.url else {
      completionHandler(nil)
      finish(.failure(WebsiteResourceLoaderError.unsafeURL))
      return
    }

    // Rebuild instead of forwarding URLSession's redirect request so response
    // cookies or origin-specific authorization can never ride to another host.
    var sanitized = URLRequest(url: nextURL)
    sanitized.httpMethod = "GET"
    sanitized.cachePolicy = .reloadIgnoringLocalCacheData
    sanitized.timeoutInterval = request.timeoutInterval
    sanitized.setValue(request.value(forHTTPHeaderField: "Accept"), forHTTPHeaderField: "Accept")
    completionHandler(sanitized)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      finish(.failure(WebsiteResourceLoaderError.authenticationRequired))
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let httpResponse = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(WebsiteResourceLoaderError.invalidResponse))
      return
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      completionHandler(.cancel)
      finish(.failure(WebsiteResourceLoaderError.unacceptableStatus(httpResponse.statusCode)))
      return
    }
    if httpResponse.expectedContentLength > Int64(maximumBytes) {
      completionHandler(.cancel)
      finish(.failure(WebsiteResourceLoaderError.responseTooLarge))
      return
    }
    lock.lock()
    self.response = httpResponse
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    guard data.count <= maximumBytes,
      receivedData.count <= maximumBytes - data.count
    else {
      lock.unlock()
      dataTask.cancel()
      finish(.failure(WebsiteResourceLoaderError.responseTooLarge))
      return
    }
    receivedData.append(data)
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
        finish(
          .failure(
            isCancellationRequested
              ? WebsiteResourceLoaderError.cancelled
              : WebsiteResourceLoaderError.networkFailure
          ))
      } else {
        finish(.failure(WebsiteResourceLoaderError.networkFailure))
      }
      return
    }

    lock.lock()
    let response = self.response
    let data = receivedData
    lock.unlock()
    guard let response, let finalURL = response.url else {
      finish(.failure(WebsiteResourceLoaderError.invalidResponse))
      return
    }
    finish(
      .success(
        WebsiteResourceResponse(
          data: data,
          mimeType: response.mimeType?.lowercased(),
          finalURL: finalURL,
          statusCode: response.statusCode
        )))
  }

  private func finish(_ result: Result<WebsiteResourceResponse, Error>) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    let continuation = self.continuation
    self.continuation = nil
    let session = self.session
    self.session = nil
    self.task = nil
    lock.unlock()

    session?.finishTasksAndInvalidate()
    continuation?.resume(with: result)
  }

  private var isCancellationRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancellationRequested
  }
}

private enum WebsiteMIMEPolicy {
  static func acceptsHTML(_ mimeType: String?, data: Data) -> Bool {
    switch normalized(mimeType) {
    case "text/html", "application/xhtml+xml": return true
    case nil:
      let prefix = String(decoding: data.prefix(512), as: Unicode.UTF8.self).lowercased()
      return prefix.contains("<html") || prefix.contains("<head") || prefix.contains("<link")
    default: return false
    }
  }

  static func acceptsImage(_ mimeType: String?, resourceURL: URL) -> Bool {
    switch normalized(mimeType) {
    case "image/png", "image/x-png", "image/jpeg", "image/jpg", "image/pjpeg", "image/gif",
      "image/vnd.microsoft.icon", "image/x-icon":
      return true
    case nil:
      // Missing MIME is tolerated only because ImageIO performs the final,
      // format-whitelisted decode before any bytes can reach a View.
      return true
    case "application/octet-stream":
      return ["ico", "png", "jpg", "jpeg", "gif"]
        .contains(resourceURL.pathExtension.lowercased())
    default:
      return false
    }
  }

  private static func normalized(_ mimeType: String?) -> String? {
    guard let mimeType else { return nil }
    let value =
      mimeType
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return value?.isEmpty == false ? value : nil
  }
}
