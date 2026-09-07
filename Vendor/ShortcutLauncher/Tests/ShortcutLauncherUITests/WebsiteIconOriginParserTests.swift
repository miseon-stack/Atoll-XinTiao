import Foundation
import XCTest

@testable import ShortcutLauncherUI

final class WebsiteIconOriginParserTests: XCTestCase {
  func testOriginKeepsOnlyNormalizedOriginAndHashesCacheFileIdentity() throws {
    let origin = try WebsiteOrigin(
      websiteURL: XCTUnwrap(URL(string: "HTTPS://例子.测试:443/private?q=secret#fragment"))
    )

    XCTAssertEqual(origin.scheme, "https")
    XCTAssertEqual(origin.host, "xn--fsqu00a.xn--0zwm56d")
    XCTAssertNil(origin.port)
    XCTAssertEqual(origin.normalizedString, "https://xn--fsqu00a.xn--0zwm56d")
    XCTAssertEqual(origin.rootURL.absoluteString, "https://xn--fsqu00a.xn--0zwm56d/")
    XCTAssertEqual(origin.cacheKey.count, 64)
    XCTAssertFalse(origin.cacheKey.contains("xn--"))
  }

  func testOriginPreservesOnlyNonDefaultPortAndIPv6Syntax() throws {
    let origin = try WebsiteOrigin("http://[::1]:8080/path")

    XCTAssertEqual(origin.host, "::1")
    XCTAssertEqual(origin.port, 8080)
    XCTAssertEqual(origin.normalizedString, "http://[::1]:8080")
    XCTAssertEqual(origin.rootURL.absoluteString, "http://[::1]:8080/")
  }

  func testOriginRejectsCredentialsAndUnsupportedSchemes() throws {
    XCTAssertThrowsError(try WebsiteOrigin("https://user:password@example.com/private")) {
      XCTAssertEqual($0 as? WebsiteOriginError, .embeddedCredentials)
    }
    XCTAssertThrowsError(try WebsiteOrigin("file:///tmp/icon")) {
      XCTAssertEqual($0 as? WebsiteOriginError, .unsupportedScheme)
    }
  }

  func testParserHandlesCaseAttributeOrderQuotesEntitiesAndRelativeURLs() throws {
    let html = """
      <HTML><HEAD>
        <LINK HREF='/small.png?a=1&amp;b=2' SIZES='32x32' REL='ICON' TYPE='image/png'>
        <link sizes=180x180 href="//cdn.example.net/touch.png" rel="apple-touch-icon">
        <link rel='shortcut ICON' href=legacy.ico type='image/x-icon'>
      </HEAD><BODY><link rel="icon" href="/must-not-appear.png"></BODY></HTML>
      """

    let candidates = FaviconLinkParser().candidates(
      in: Data(html.utf8),
      documentURL: try XCTUnwrap(URL(string: "https://example.com/root/")),
      limit: 8
    )

    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(candidates[0].url.absoluteString, "https://example.com/small.png?a=1&b=2")
    XCTAssertEqual(candidates[0].declaredPixelSize, 32)
    XCTAssertEqual(candidates[1].url.absoluteString, "https://example.com/root/legacy.ico")
    XCTAssertEqual(candidates[1].relationship, .shortcutIcon)
    XCTAssertEqual(candidates[2].url.absoluteString, "https://cdn.example.net/touch.png")
    XCTAssertEqual(candidates[2].relationship, .appleTouchIcon)
    XCTAssertFalse(candidates.contains(where: { $0.url.path.contains("must-not-appear") }))
  }

  func testParserSortsSafeRasterFormatsThenSizeAndDeduplicates() throws {
    let html = """
      <head>
        <link rel="icon" type="image/svg+xml" sizes="512x512" href="/vector.svg">
        <link rel="icon" type="image/png" sizes="32x32" href="/small.png">
        <link rel="icon" type="image/png" sizes="128x128" href="/large.png#one">
        <link rel="icon" type="image/png" sizes="128x128" href="/large.png#two">
        <link rel="icon" href="javascript:alert(1)">
        <link rel="icon" href="data:image/png;base64,AAAA">
      </head>
      """

    let candidates = FaviconLinkParser().candidates(
      in: Data(html.utf8),
      documentURL: try XCTUnwrap(URL(string: "https://example.com/")),
      limit: 8
    )

    XCTAssertEqual(
      candidates.prefix(2).map(\.url.absoluteString),
      [
        "https://example.com/large.png",
        "https://example.com/small.png",
      ])
  }

  func testSafetyCheckerAllowsDeclaredPublicHTTPSCDNButRejectsPivotAndDowngrade() throws {
    let checker = DefaultWebsiteURLSafetyChecker(
      resolver: FixtureHostResolver(values: [
        "example.com": .publicOnly,
        "cdn.example.net": .publicOnly,
        "second-cdn.example": .publicOnly,
        "private.example": .containsNonPublicAddress,
      ]))
    let origin = try WebsiteOrigin("https://example.com/private/path")

    XCTAssertTrue(
      checker.allows(
        try XCTUnwrap(URL(string: "https://cdn.example.net/icon.png")),
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: nil
      ))
    XCTAssertFalse(
      checker.allows(
        try XCTUnwrap(URL(string: "http://cdn.example.net/icon.png")),
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: nil
      ))
    XCTAssertFalse(
      checker.allows(
        try XCTUnwrap(URL(string: "https://private.example/icon.png")),
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: nil
      ))
    XCTAssertFalse(
      checker.allows(
        try XCTUnwrap(URL(string: "https://cdn.example.net/icon.png")),
        initialOrigin: origin,
        resourceKind: .fallbackIcon,
        redirectSource: nil
      ))
    XCTAssertFalse(
      checker.allows(
        try XCTUnwrap(URL(string: "https://second-cdn.example/icon.png")),
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: try XCTUnwrap(URL(string: "https://cdn.example.net/icon.png"))
      ))
  }

  func testSafetyCheckerKeepsExplicitLocalBindingOnExactOrigin() throws {
    let checker = DefaultWebsiteURLSafetyChecker(resolver: FixtureHostResolver(values: [:]))
    let origin = try WebsiteOrigin("http://127.0.0.1:8080/private")

    XCTAssertTrue(
      checker.allows(
        try XCTUnwrap(URL(string: "http://127.0.0.1:8080/favicon.ico")),
        initialOrigin: origin,
        resourceKind: .fallbackIcon,
        redirectSource: nil
      ))
    XCTAssertFalse(
      checker.allows(
        try XCTUnwrap(URL(string: "http://127.0.0.1:9090/favicon.ico")),
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: nil
      ))
    XCTAssertFalse(
      checker.allows(
        try XCTUnwrap(URL(string: "http://192.168.1.2/favicon.ico")),
        initialOrigin: origin,
        resourceKind: .declaredIcon,
        redirectSource: nil
      ))
  }

  func testSafetyCheckerDoesNotTreatPublicLookingPrivateDNSAsExplicitLocal() throws {
    let checker = DefaultWebsiteURLSafetyChecker(
      resolver: FixtureHostResolver(values: [
        "public-looking.example": .containsNonPublicAddress
      ]))
    let origin = try WebsiteOrigin("https://public-looking.example/private")

    XCTAssertFalse(
      checker.allows(
        origin.rootURL,
        initialOrigin: origin,
        resourceKind: .originHTML,
        redirectSource: nil
      ))
  }

  func testSystemResolverClassifiesIPLiteralRangesWithoutNetworkLookup() {
    let resolver = SystemWebsiteHostAddressResolver()

    XCTAssertEqual(resolver.resolution(for: "127.0.0.1"), .containsNonPublicAddress)
    XCTAssertEqual(resolver.resolution(for: "10.0.0.1"), .containsNonPublicAddress)
    XCTAssertEqual(resolver.resolution(for: "169.254.1.2"), .containsNonPublicAddress)
    XCTAssertEqual(resolver.resolution(for: "::1"), .containsNonPublicAddress)
    XCTAssertEqual(resolver.resolution(for: "fc00::1"), .containsNonPublicAddress)
    XCTAssertEqual(resolver.resolution(for: "8.8.8.8"), .publicOnly)
    XCTAssertEqual(resolver.resolution(for: "2606:4700:4700::1111"), .publicOnly)
  }
}

private struct FixtureHostResolver: WebsiteHostAddressResolving {
  let values: [String: WebsiteHostResolution]

  func resolution(for host: String) -> WebsiteHostResolution {
    values[host] ?? .unavailable
  }
}
