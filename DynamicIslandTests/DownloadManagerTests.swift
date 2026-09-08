import XCTest
@testable import Atoll

final class DownloadManagerTests: XCTestCase {
    func testMissingDownloadFolderDoesNotProduceACompletionEvent() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(DownloadManager.downloadFiles(in: missing))
    }

    func testSnapshotRecognizesDownloadsWithoutReadingTheirContents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["pending.crdownload", "other.DOWNLOAD", "finished.pdf"]
        for name in names {
            XCTAssertTrue(FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data()))
        }
        let snapshot = try XCTUnwrap(DownloadManager.downloadFiles(in: folder))
        XCTAssertEqual(snapshot.inProgress, ["pending.crdownload", "other.DOWNLOAD"])
        XCTAssertEqual(snapshot.all, Set(names))
    }
}
