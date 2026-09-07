import Foundation
import ShortcutLauncherCore
import UniformTypeIdentifiers
import XCTest

@testable import ShortcutLauncherUI

@MainActor
final class LauncherDropCoordinatorTests: XCTestCase {
  func testFileFolderAndApplicationURLsResolveToExpectedTargetKinds() throws {
    let fixture = try DropFixture()
    defer { fixture.remove() }
    let file = try fixture.createFile(named: "notes.txt")
    let folder = try fixture.createFolder(named: "Projects")
    let application = try fixture.createApplication(named: "Fixture")
    let resolver = DropTargetResolver()

    XCTAssertEqual(try externalTarget(resolver.resolve(item: .fileURL(file))).kind, .file)
    XCTAssertEqual(try externalTarget(resolver.resolve(item: .fileURL(folder))).kind, .folder)
    let applicationTarget = try externalTarget(
      resolver.resolve(item: .fileURL(application))
    )
    XCTAssertEqual(applicationTarget.kind, .application)
    XCTAssertEqual(applicationTarget.displayName, "Fixture")
    XCTAssertNil(applicationTarget.bookmarkData)
  }

  func testFakeApplicationPackageIsRejected() throws {
    let fixture = try DropFixture()
    defer { fixture.remove() }
    let fakeApplication = try fixture.createFolder(named: "NotAnApplication.app")

    XCTAssertThrowsError(
      try DropTargetResolver().resolve(item: .fileURL(fakeApplication))
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .invalidApplication)
    }
  }

  func testMissingLocalTargetIsRejectedWithoutLeakingItsPath() throws {
    let fixture = try DropFixture()
    defer { fixture.remove() }
    let missing = fixture.root.appendingPathComponent("private-secret.txt")

    XCTAssertThrowsError(
      try DropTargetResolver().resolve(item: .fileURL(missing))
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .targetUnavailable)
      XCTAssertFalse(error.localizedDescription.contains("private-secret"))
    }
  }

  func testHTTPAndHTTPSURLsResolveButDangerousSchemesDoNot() throws {
    let resolver = DropTargetResolver(fileInspector: StubDropFileInspector())
    let httpsTarget = try externalTarget(
      resolver.resolve(item: .webURL(URL(string: "https://x.com/path?q=private")!))
    )
    let httpTarget = try externalTarget(
      resolver.resolve(item: .webURL(URL(string: "http://localhost:8080/")!))
    )

    XCTAssertEqual(httpsTarget.kind, .web)
    XCTAssertEqual(httpsTarget.lastKnownURL.absoluteString, "https://x.com/path?q=private")
    XCTAssertEqual(httpsTarget.displayName, "x.com")
    XCTAssertEqual(httpTarget.displayName, "localhost:8080")

    for rawValue in [
      "file:///tmp/private.txt",
      "javascript:alert(1)",
      "data:text/plain,hello",
      "ftp://example.com/file",
    ] {
      XCTAssertThrowsError(
        try resolver.resolve(item: .webURL(URL(string: rawValue)!)),
        "Expected \(rawValue) to be rejected"
      ) { error in
        XCTAssertTrue(
          error as? LauncherDropError == .unsupportedRepresentation
            || error as? LauncherDropError == .unsupportedURLScheme
        )
      }
    }
  }

  func testPlainTextOnlyAcceptsExplicitHTTPOrHTTPSAndRejectsFileMasquerading() throws {
    let resolver = DropTargetResolver(fileInspector: StubDropFileInspector())

    let target = try externalTarget(
      resolver.resolve(item: .plainText(" https://example.com/welcome "))
    )
    XCTAssertEqual(target.kind, .web)
    XCTAssertEqual(target.displayName, "example.com")

    for value in [
      "example.com",
      "file:///tmp/secret.txt",
      "/tmp/secret.txt",
      "~/Desktop/secret.txt",
      "javascript:alert(1)",
    ] {
      XCTAssertThrowsError(
        try resolver.resolve(item: .plainText(value)),
        "Expected text representation \(value) to be rejected"
      )
    }
  }

  func testMultipleItemsAndConflictingRepresentationsAreRejected() throws {
    let resolver = DropTargetResolver(fileInspector: StubDropFileInspector())

    XCTAssertThrowsError(try resolver.resolve(items: [])) { error in
      XCTAssertEqual(error as? LauncherDropError, .noTarget)
    }
    XCTAssertThrowsError(
      try resolver.resolve(items: [
        .plainText("https://a.example"),
        .plainText("https://b.example"),
      ])
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .multipleTargets)
    }
    XCTAssertThrowsError(
      try resolver.resolve(
        item: LauncherDropItem(
          url: URL(string: "https://a.example")!,
          plainText: "https://b.example"
        ))
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .ambiguousRepresentations)
    }
  }

  func testEquivalentURLAndTextRepresentationsResolveAsOneProviderItem() throws {
    let resolver = DropTargetResolver(fileInspector: StubDropFileInspector())
    let url = URL(string: "https://example.com/path")!

    let target = try externalTarget(
      resolver.resolve(
        item: LauncherDropItem(
          url: url,
          plainText: url.absoluteString
        )))

    XCTAssertEqual(target.lastKnownURL, url)
  }

  func testInternalSlotUsesDedicatedTypeAndVersionedPayload() throws {
    let transfer = LauncherSlotTransfer(sourceKeyCode: 12)
    let data = try transfer.encodedData()
    let resolved = try DropTargetResolver(fileInspector: StubDropFileInspector())
      .resolve(item: LauncherDropItem(internalSlotData: data))

    XCTAssertEqual(resolved, .internalSlot(transfer))
    XCTAssertNotEqual(UTType.shortcutLauncherSlotTransfer, .plainText)
    XCTAssertNotEqual(UTType.shortcutLauncherSlotTransfer, .url)
    XCTAssertNotEqual(UTType.shortcutLauncherSlotTransfer, .fileURL)

    let future = LauncherSlotTransfer(payloadVersion: 99, sourceKeyCode: 12)
    let futureData = try JSONEncoder().encode(future)
    XCTAssertThrowsError(
      try DropTargetResolver(fileInspector: StubDropFileInspector())
        .resolve(item: LauncherDropItem(internalSlotData: futureData))
    ) { error in
      XCTAssertEqual(
        error as? LauncherDropError,
        .unsupportedInternalPayloadVersion(99)
      )
    }
  }

  func testInternalAndExternalRepresentationsCannotBeMixed() throws {
    let item = LauncherDropItem(
      internalSlotData: try LauncherSlotTransfer(sourceKeyCode: 12).encodedData(),
      plainText: "https://example.com"
    )

    XCTAssertThrowsError(
      try DropTargetResolver(fileInspector: StubDropFileInspector()).resolve(item: item)
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .ambiguousRepresentations)
    }
  }

  func testCoordinatorBuildsBindAndReplacementPlansWithoutMutatingBindings() throws {
    let resolver = DropTargetResolver(fileInspector: StubDropFileInspector())
    let coordinator = LauncherDropCoordinator(resolver: resolver)
    let webItem = LauncherDropItem.plainText("https://x.com")
    let existing = binding(keyCode: 13, id: "existing")
    let bindings = [UInt16(13): existing]

    let bind = try coordinator.prepare(
      items: [webItem],
      destinationKeyCode: 12,
      bindings: bindings
    )
    let replace = try coordinator.prepare(
      items: [webItem],
      destinationKeyCode: 13,
      bindings: bindings
    )

    XCTAssertEqual(
      bind,
      .bind(
        target: webTarget("x.com"),
        destinationKeyCode: 12
      ))
    XCTAssertEqual(
      replace,
      .replace(
        target: webTarget("x.com"),
        destinationKeyCode: 13,
        replacedBindingID: existing.id
      ))
    XCTAssertFalse(bind.requiresReplacementConfirmation)
    XCTAssertTrue(replace.requiresReplacementConfirmation)
    XCTAssertEqual(bindings, [13: existing])
  }

  func testCoordinatorBuildsMoveAndSwapPlansForValidInternalSource() throws {
    let coordinator = LauncherDropCoordinator(
      resolver: DropTargetResolver(fileInspector: StubDropFileInspector())
    )
    let item = try LauncherDropItem.internalSlot(
      LauncherSlotTransfer(sourceKeyCode: 12)
    )
    let source = binding(keyCode: 12, id: "source")
    let destination = binding(keyCode: 13, id: "destination")

    XCTAssertEqual(
      try coordinator.prepare(
        items: [item],
        destinationKeyCode: 13,
        bindings: [12: source]
      ),
      .move(sourceKeyCode: 12, destinationKeyCode: 13)
    )
    XCTAssertEqual(
      try coordinator.prepare(
        items: [item],
        destinationKeyCode: 13,
        bindings: [12: source, 13: destination]
      ),
      .swap(sourceKeyCode: 12, destinationKeyCode: 13)
    )
  }

  func testCoordinatorRejectsInvalidDestinationMissingSourceAndSameSlot() throws {
    let coordinator = LauncherDropCoordinator(
      resolver: DropTargetResolver(fileInspector: StubDropFileInspector())
    )
    let item = try LauncherDropItem.internalSlot(
      LauncherSlotTransfer(sourceKeyCode: 12)
    )
    let source = binding(keyCode: 12, id: "source")

    XCTAssertThrowsError(
      try coordinator.prepare(
        items: [item],
        destinationKeyCode: 999,
        bindings: [12: source]
      )
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .invalidSlot)
    }
    XCTAssertThrowsError(
      try coordinator.prepare(
        items: [item],
        destinationKeyCode: 13,
        bindings: [:]
      )
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .missingSourceBinding)
    }
    XCTAssertThrowsError(
      try coordinator.prepare(
        items: [item],
        destinationKeyCode: 12,
        bindings: [12: source]
      )
    ) { error in
      XCTAssertEqual(error as? LauncherDropError, .sameSlot)
    }
  }

  private func externalTarget(_ result: ResolvedLauncherDrop) throws -> LaunchTarget {
    guard case .externalTarget(let target) = result else {
      throw TestFailure.unexpectedInternalDrop
    }
    return target
  }

  private func binding(keyCode: UInt16, id: String) -> BindingRecord {
    BindingRecord(
      id: BindingID(rawValue: id),
      physicalKeyCode: keyCode,
      target: webTarget("existing.example")
    )
  }

  private func webTarget(_ host: String) -> LaunchTarget {
    LaunchTarget(
      kind: .web,
      displayName: host,
      lastKnownURL: URL(string: "https://\(host)")!
    )
  }
}

private enum TestFailure: Error {
  case unexpectedInternalDrop
}

private struct StubDropFileInspector: LauncherDropFileInspecting {
  func metadata(forFileURL url: URL) -> LauncherDropFileMetadata {
    LauncherDropFileMetadata(
      exists: false,
      isDirectory: false,
      isApplication: false,
      displayName: "fixture",
      normalizedURL: url
    )
  }
}

private final class DropFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LauncherDropCoordinatorTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func createFile(named name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: false)
    try Data("fixture".utf8).write(to: url)
    return url
  }

  func createFolder(named name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func createApplication(named name: String) throws -> URL {
    let applicationURL = root.appendingPathComponent("\(name).app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleDisplayName": name,
      "CFBundleIdentifier": "fixture.\(name.lowercased())",
      "CFBundlePackageType": "APPL",
      "CFBundleExecutable": "FixtureExecutable",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return applicationURL
  }
}
