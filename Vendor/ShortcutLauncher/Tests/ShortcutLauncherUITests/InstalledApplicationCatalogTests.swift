import Foundation
import XCTest

@testable import ShortcutLauncherUI

@MainActor
final class InstalledApplicationCatalogTests: XCTestCase {
  func testScanFindsNestedAppsButDoesNotEnterApplicationPackages() async throws {
    let fixture = try ApplicationCatalogFixture()
    defer { fixture.remove() }
    let root = fixture.root.appendingPathComponent("Applications", isDirectory: true)
    try fixture.createDirectory(root.appendingPathComponent("Communication", isDirectory: true))
    let weChat = try fixture.createApplication(
      at: root.appendingPathComponent("Communication/WeChat.app", isDirectory: true),
      displayName: "微信",
      bundleIdentifier: "com.tencent.xinWeChat"
    )
    _ = try fixture.createApplication(
      at: weChat.appendingPathComponent("Contents/PlugIns/Hidden.app", isDirectory: true),
      displayName: "不应出现",
      bundleIdentifier: "fixture.hidden"
    )
    _ = try fixture.createApplication(
      at: root.appendingPathComponent("Notes.app", isDirectory: true),
      displayName: "备忘录",
      bundleIdentifier: "fixture.notes"
    )
    let catalog = InstalledApplicationCatalog(
      searchRoots: [root],
      fileManager: FixtureApplicationFileManager()
    )

    let applications = await catalog.applications()

    XCTAssertEqual(applications.count, 2)
    XCTAssertEqual(Set(applications.map(\.bundleIdentifier)), [
      "com.tencent.xinWeChat",
      "fixture.notes",
    ])
    let descriptor = try XCTUnwrap(
      applications.first(where: { $0.bundleIdentifier == "com.tencent.xinWeChat" })
    )
    XCTAssertEqual(descriptor.displayName, "微信")
    XCTAssertEqual(descriptor.url, weChat.standardizedFileURL.resolvingSymlinksInPath())
    XCTAssertTrue(descriptor.searchAliases.contains("wei xin"))
    XCTAssertTrue(descriptor.searchAliases.contains("wx"))
    XCTAssertFalse(applications.contains(where: { $0.bundleIdentifier == "fixture.hidden" }))
  }

  func testScanDeduplicatesRepeatedRootsURLsAndBundleIdentifiersDeterministically() async throws {
    let fixture = try ApplicationCatalogFixture()
    defer { fixture.remove() }
    let firstRoot = fixture.root.appendingPathComponent("First", isDirectory: true)
    let secondRoot = fixture.root.appendingPathComponent("Second", isDirectory: true)
    let preferred = try fixture.createApplication(
      at: firstRoot.appendingPathComponent("Preferred.app", isDirectory: true),
      displayName: "Preferred",
      bundleIdentifier: "fixture.duplicate"
    )
    _ = try fixture.createApplication(
      at: secondRoot.appendingPathComponent("Duplicate.app", isDirectory: true),
      displayName: "Duplicate",
      bundleIdentifier: "FIXTURE.DUPLICATE"
    )
    let catalog = InstalledApplicationCatalog(
      searchRoots: [firstRoot, firstRoot, secondRoot],
      fileManager: FixtureApplicationFileManager()
    )

    let applications = await catalog.applications()

    XCTAssertEqual(applications.count, 1)
    XCTAssertEqual(applications[0].url, preferred.standardizedFileURL.resolvingSymlinksInPath())
    XCTAssertEqual(applications[0].id, "bundle:fixture.duplicate")
  }

  func testApplicationsCacheIsStableUntilRefreshOrInvalidation() async throws {
    let fixture = try ApplicationCatalogFixture()
    defer { fixture.remove() }
    let root = fixture.root.appendingPathComponent("Applications", isDirectory: true)
    _ = try fixture.createApplication(
      at: root.appendingPathComponent("Alpha.app", isDirectory: true),
      displayName: "Alpha",
      bundleIdentifier: "fixture.alpha"
    )
    let catalog = InstalledApplicationCatalog(
      searchRoots: [root],
      fileManager: FixtureApplicationFileManager()
    )
    let initialNames = await catalog.applications().map(\.displayName)
    XCTAssertEqual(initialNames, ["Alpha"])

    _ = try fixture.createApplication(
      at: root.appendingPathComponent("Beta.app", isDirectory: true),
      displayName: "Beta",
      bundleIdentifier: "fixture.beta"
    )

    let cachedNames = await catalog.applications().map(\.displayName)
    let refreshedNames = await catalog.applications(forceRefresh: true).map(\.displayName)
    XCTAssertEqual(cachedNames, ["Alpha"])
    XCTAssertEqual(refreshedNames, ["Alpha", "Beta"])

    _ = try fixture.createApplication(
      at: root.appendingPathComponent("Gamma.app", isDirectory: true),
      displayName: "Gamma",
      bundleIdentifier: "fixture.gamma"
    )
    await catalog.invalidate()
    let invalidatedNames = await catalog.applications().map(\.displayName)
    XCTAssertEqual(invalidatedNames, ["Alpha", "Beta", "Gamma"])
  }

  func testSearchMatchesChinesePinyinInitialsFilenameAndBundleIdentifier() async throws {
    let fixture = try ApplicationCatalogFixture()
    defer { fixture.remove() }
    let root = fixture.root.appendingPathComponent("Applications", isDirectory: true)
    _ = try fixture.createApplication(
      at: root.appendingPathComponent("WeChat.app", isDirectory: true),
      displayName: "微信",
      bundleIdentifier: "com.tencent.xinWeChat"
    )
    _ = try fixture.createApplication(
      at: root.appendingPathComponent("Calendar.app", isDirectory: true),
      displayName: "日历",
      bundleIdentifier: "fixture.calendar"
    )
    let catalog = InstalledApplicationCatalog(
      searchRoots: [root],
      fileManager: FixtureApplicationFileManager()
    )

    let chineseNames = await catalog.search(query: "微信").map(\.displayName)
    let pinyinNames = await catalog.search(query: "wei xin").map(\.displayName)
    let compactPinyinNames = await catalog.search(query: "weixin").map(\.displayName)
    let initialNames = await catalog.search(query: "wx").map(\.displayName)
    let filenameNames = await catalog.search(query: "wechat").map(\.displayName)
    let bundleNames = await catalog.search(query: "tencent").map(\.displayName)
    XCTAssertEqual(chineseNames, ["微信"])
    XCTAssertEqual(pinyinNames, ["微信"])
    XCTAssertEqual(compactPinyinNames, ["微信"])
    XCTAssertEqual(initialNames, ["微信"])
    XCTAssertEqual(filenameNames, ["微信"])
    XCTAssertEqual(bundleNames, ["微信"])
  }

  func testPrewarmBuildsFixtureIndexOnceAndSearchReusesIt() async throws {
    let fixture = try ApplicationCatalogFixture()
    defer { fixture.remove() }
    let root = fixture.root.appendingPathComponent("Applications", isDirectory: true)
    _ = try fixture.createApplication(
      at: root.appendingPathComponent("WeChat.app", isDirectory: true),
      displayName: "微信",
      bundleIdentifier: "com.tencent.xinWeChat"
    )
    let fileManager = CountingApplicationFileManager()
    let catalog = InstalledApplicationCatalog(
      searchRoots: [root],
      fileManager: fileManager
    )

    let warmed = await catalog.prewarm()
    let callsAfterWarmup = fileManager.childURLCallCount
    let results = await catalog.search(query: "wx", limit: 8)

    XCTAssertEqual(warmed.map(\.displayName), ["微信"])
    XCTAssertEqual(results.map(\.displayName), ["微信"])
    XCTAssertEqual(fileManager.childURLCallCount, callsAfterWarmup)

    _ = await catalog.prewarm(forceRefresh: true)
    XCTAssertGreaterThan(fileManager.childURLCallCount, callsAfterWarmup)
  }
}

private struct FixtureApplicationFileManager: InstalledApplicationFileManaging {
  private let base = DefaultInstalledApplicationFileManager()

  func childURLs(at directoryURL: URL) throws -> [URL] {
    try base.childURLs(at: directoryURL)
  }

  func isDirectory(at url: URL) -> Bool {
    base.isDirectory(at: url)
  }

  func metadata(forApplicationAt applicationURL: URL) -> InstalledApplicationMetadata {
    base.metadata(forApplicationAt: applicationURL)
  }
}

private final class CountingApplicationFileManager: InstalledApplicationFileManaging,
  @unchecked Sendable
{
  private let base = DefaultInstalledApplicationFileManager()
  private let lock = NSLock()
  private var storedChildURLCallCount = 0

  var childURLCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedChildURLCallCount
  }

  func childURLs(at directoryURL: URL) throws -> [URL] {
    lock.lock()
    storedChildURLCallCount += 1
    lock.unlock()
    return try base.childURLs(at: directoryURL)
  }

  func isDirectory(at url: URL) -> Bool {
    base.isDirectory(at: url)
  }

  func metadata(forApplicationAt applicationURL: URL) -> InstalledApplicationMetadata {
    base.metadata(forApplicationAt: applicationURL)
  }
}

private final class ApplicationCatalogFixture {
  let root: URL
  private let fileManager = FileManager.default

  init() throws {
    root = fileManager.temporaryDirectory
      .appendingPathComponent("InstalledApplicationCatalogTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func remove() {
    try? fileManager.removeItem(at: root)
  }

  func createDirectory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
  }

  @discardableResult
  func createApplication(
    at url: URL,
    displayName: String,
    bundleIdentifier: String
  ) throws -> URL {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
    let propertyList: [String: Any] = [
      "CFBundleDisplayName": displayName,
      "CFBundleName": displayName,
      "CFBundleIdentifier": bundleIdentifier,
      "CFBundlePackageType": "APPL",
      "CFBundleExecutable": "FixtureExecutable",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: propertyList,
      format: .xml,
      options: 0
    )
    try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    return url
  }
}
