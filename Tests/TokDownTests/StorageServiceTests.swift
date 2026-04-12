import XCTest
@testable import TokDown

final class StorageServiceTests: XCTestCase {
    func testSessionArtifactsAddsDeterministicSuffixWhenMinuteCollides() throws {
        let folder = try makeTempFolder()
        let service = StorageService()
        let startTime = date("2026-03-13T14:00:00Z")

        let first = try service.sessionArtifacts(folderBase: folder, title: "Weekly Sync", startTime: startTime)
        FileManager.default.createFile(atPath: first.audioURL.path, contents: Data())
        FileManager.default.createFile(atPath: first.transcriptURL.path, contents: Data())

        let second = try service.sessionArtifacts(folderBase: folder, title: "Weekly Sync", startTime: startTime)

        let expectedBase = expectedBaseName(for: startTime, title: "Weekly Sync")

        XCTAssertEqual(first.audioURL.lastPathComponent, "\(expectedBase).m4a")
        XCTAssertEqual(first.transcriptURL.lastPathComponent, "\(expectedBase).md")
        XCTAssertEqual(second.audioURL.lastPathComponent, "\(expectedBase)-2.m4a")
        XCTAssertEqual(second.transcriptURL.lastPathComponent, "\(expectedBase)-2.md")
    }

    func testTranscriptURLAddsSuffixWithoutChangingDateFirstPrefix() throws {
        let folder = try makeTempFolder()
        let service = StorageService()
        let startTime = date("2026-03-13T14:00:00Z")

        let existing = service.transcriptURL(folderBase: folder, title: "Recording", startTime: startTime)
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        let next = service.transcriptURL(folderBase: folder, title: "Recording", startTime: startTime)

        let expectedBase = expectedBaseName(for: startTime, title: "Recording")
        let expectedPrefix = expectedDatePrefix(for: startTime)

        XCTAssertEqual(existing.lastPathComponent, "\(expectedBase).md")
        XCTAssertEqual(next.lastPathComponent, "\(expectedBase)-2.md")
        XCTAssertTrue(next.lastPathComponent.hasPrefix("\(expectedPrefix)_"))
    }

    func testDeleteFileUsesPermanentRemovalInsteadOfTrash() {
        let fileURL = URL(fileURLWithPath: "/tmp/sample.m4a")
        let fileManager = TrackingFileManager()
        let service = StorageService(fileManager: fileManager)

        XCTAssertEqual(service.deleteFile(fileURL), .deleted)
        XCTAssertEqual(fileManager.removedURLs, [fileURL])
        XCTAssertTrue(fileManager.trashedURLs.isEmpty)
    }

    func testDeleteFileReportsFailureForMissingFile() throws {
        let folder = try makeTempFolder()
        let service = StorageService()
        let missingURL = folder.appendingPathComponent("missing.m4a")

        guard case .failed(let message) = service.deleteFile(missingURL) else {
            return XCTFail("Expected delete failure for missing file")
        }
        XCTAssertFalse(message.isEmpty)
    }

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func expectedBaseName(for date: Date, title: String) -> String {
        "\(expectedDatePrefix(for: date))_\(title)"
    }

    private func expectedDatePrefix(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter.string(from: date)
    }
}

private final class TrackingFileManager: FileManager {
    private(set) var removedURLs: [URL] = []
    private(set) var trashedURLs: [URL] = []

    override func removeItem(at url: URL) throws {
        removedURLs.append(url)
    }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        trashedURLs.append(url)
    }
}
