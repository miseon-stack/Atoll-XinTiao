import XCTest

@testable import ShortcutLauncherCore

final class WebURLValidatorTests: XCTestCase {
  func testAcceptsHTTPAndHTTPS() throws {
    XCTAssertEqual(
      try WebURLValidator.normalize("https://example.com/path").absoluteString,
      "https://example.com/path"
    )
    XCTAssertEqual(
      try WebURLValidator.normalize(" http://example.com ").absoluteString,
      "http://example.com"
    )
  }

  func testAddsHTTPSForBareDomainsAndPreservesComponents() throws {
    XCTAssertEqual(
      try WebURLValidator.normalize("example.com").absoluteString,
      "https://example.com"
    )
    XCTAssertEqual(
      try WebURLValidator.normalize("www.example.com/path?q=1#part").absoluteString,
      "https://www.example.com/path?q=1#part"
    )
    XCTAssertEqual(
      try WebURLValidator.normalize("localhost:3000").absoluteString,
      "https://localhost:3000"
    )
    XCTAssertEqual(
      try WebURLValidator.normalize("example.com:8443/path?q=1").absoluteString,
      "https://example.com:8443/path?q=1"
    )
  }

  func testNormalizesExplicitSchemeCase() throws {
    XCTAssertEqual(
      try WebURLValidator.normalize("HTTPS://example.com/path").absoluteString,
      "https://example.com/path"
    )
  }

  func testRejectsUnsupportedScheme() {
    XCTAssertThrowsError(try WebURLValidator.normalize("file:///tmp/example")) { error in
      XCTAssertEqual(error as? LauncherError, .unsupportedURLScheme)
    }

    for value in ["ftp://example.com", "javascript:alert(1)", "mailto:user@example.com"] {
      XCTAssertThrowsError(try WebURLValidator.normalize(value)) { error in
        XCTAssertEqual(error as? LauncherError, .unsupportedURLScheme)
      }
    }
  }

  func testRejectsMissingHostCredentialsWhitespaceAndControls() {
    XCTAssertThrowsError(try WebURLValidator.normalize("https://"))
    XCTAssertThrowsError(try WebURLValidator.normalize("   "))
    XCTAssertThrowsError(try WebURLValidator.normalize("https://user:password@example.com"))
    XCTAssertThrowsError(try WebURLValidator.normalize("https://user@example.com"))
    XCTAssertThrowsError(try WebURLValidator.normalize("example .com"))
    XCTAssertThrowsError(try WebURLValidator.normalize("example.com/path here"))
    XCTAssertThrowsError(try WebURLValidator.normalize("example.com\nmalicious.example"))
    XCTAssertThrowsError(try WebURLValidator.normalize("example.com\u{0000}"))
  }
}
