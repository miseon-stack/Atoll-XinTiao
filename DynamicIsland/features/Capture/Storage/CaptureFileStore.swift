/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import CoreGraphics
import Defaults
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor CaptureFileStore {
    static let shared = CaptureFileStore()

    func savePNG(_ image: CGImage, destination: CaptureDestination = .screenshots) throws -> CaptureArtifact {
        guard image.width > 0, image.height > 0 else { throw CaptureError.emptyFrame }
        let access = try destinationAccess(for: destination)
        defer { access.stopAccessing() }
        let finalURL = try reserveURL(in: access.folder, kind: .screenshot, extension: "png")
        let temporaryURL = access.folder.appendingPathComponent(".\(UUID().uuidString).png")

        guard let writer = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw CaptureError.encodingFailed }
        CGImageDestinationAddImage(writer, image, [
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
            kCGImagePropertyProfileName: "sRGB"
        ] as CFDictionary)
        let finalized = CGImageDestinationFinalize(writer)
        let fileSize = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard finalized, fileSize > 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw CaptureError.encodingFailed
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return CaptureArtifact(kind: .screenshot, fileURL: finalURL)
    }

    func recordingTemporaryAndFinalURLs() throws -> (temporary: URL, final: URL, stopAccessing: @Sendable () -> Void) {
        let access = try destinationAccess(for: .recordings)
        let final = try reserveURL(in: access.folder, kind: .recording, extension: "mp4")
        let temporary = access.folder.appendingPathComponent(".Atoll Recording \(UUID().uuidString).mp4")
        return (temporary, final, access.stopAccessing)
    }

    func displayFolder(for destination: CaptureDestination) throws -> URL {
        let access = try destinationAccess(for: destination)
        defer { access.stopAccessing() }
        return access.folder
    }

    static func bookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func destinationAccess(for destination: CaptureDestination) throws -> DestinationAccess {
        let preferences = Defaults[.capturePreferences]
        let bookmark = destination == .screenshots
            ? preferences.screenshotFolderBookmark
            : preferences.recordingFolderBookmark
        if let bookmark {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                guard !stale else { throw CaptureError.destinationAccessLost }
                let didAccess = url.startAccessingSecurityScopedResource()
                guard didAccess else { throw CaptureError.destinationAccessLost }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return DestinationAccess(folder: url) { url.stopAccessingSecurityScopedResource() }
            } catch let error as CaptureError {
                throw error
            } catch {
                throw CaptureError.destinationAccessLost
            }
        }

        let searchDirectory: FileManager.SearchPathDirectory = destination == .screenshots ? .picturesDirectory : .moviesDirectory
        guard let base = FileManager.default.urls(for: searchDirectory, in: .userDomainMask).first else {
            throw CaptureError.destinationAccessLost
        }
        let folderName = destination == .screenshots ? "Atoll Screenshots" : "Atoll Recordings"
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return DestinationAccess(folder: folder, stopAccessing: {})
    }

    private func reserveURL(
        in folder: URL,
        kind: CaptureArtifactKind,
        extension fileExtension: String
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let label = kind == .screenshot ? "Atoll Screenshot" : "Atoll Recording"
        let base = "\(label) \(formatter.string(from: Date()))"
        var candidate = folder.appendingPathComponent("\(base).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }
}

private struct DestinationAccess: Sendable {
    let folder: URL
    let stopAccessing: @Sendable () -> Void
}
