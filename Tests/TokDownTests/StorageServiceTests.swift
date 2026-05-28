import XCTest
@testable import TokDown

final class StorageServiceTests: XCTestCase {
    func testTemporaryAudioURLUsesAppOwnedTempFolder() throws {
        let transcriptFolder = try makeTempFolder()
        let tempFolder = try makeTempFolder()
        let service = StorageService(temporaryDirectory: tempFolder)
        let startTime = date("2026-03-13T14:00:00Z")

        let audioURL = try service.temporaryAudioURL(startTime: startTime)

        XCTAssertTrue(audioURL.path.hasPrefix(tempFolder.path))
        XCTAssertFalse(audioURL.path.hasPrefix(transcriptFolder.path))
        XCTAssertEqual(audioURL.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.deletingLastPathComponent().path))
    }

    func testTranscriptURLAddsDeterministicSuffixWhenMinuteCollides() throws {
        let folder = try makeTempFolder()
        let service = StorageService()
        let startTime = date("2026-03-13T14:00:00Z")

        let first = try service.transcriptURL(folderBase: folder, title: "Weekly Sync", startTime: startTime)
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let second = try service.transcriptURL(folderBase: folder, title: "Weekly Sync", startTime: startTime)

        let expectedBase = expectedBaseName(for: startTime, title: "Weekly Sync")

        XCTAssertEqual(first.lastPathComponent, "\(expectedBase).md")
        XCTAssertEqual(second.lastPathComponent, "\(expectedBase)-2.md")
    }

    func testCleanupTemporaryAudioFilesDeletesOnlyTokDownTempAudio() throws {
        let userFolder = try makeTempFolder()
        let tempFolder = try makeTempFolder()
        let service = StorageService(temporaryDirectory: tempFolder)

        let userAudioURL = userFolder.appendingPathComponent("unrelated.m4a")
        FileManager.default.createFile(atPath: userAudioURL.path, contents: Data())

        let tempAudioURL = try service.temporaryAudioURL(startTime: date("2026-03-13T14:00:00Z"))
        FileManager.default.createFile(atPath: tempAudioURL.path, contents: Data())

        service.cleanupTemporaryAudioFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userAudioURL.path))
    }

    func testCleanupTemporaryAudioFilesIsNoOpForMissingFolder() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)", isDirectory: true)
        let service = StorageService(temporaryDirectory: missing)

        service.cleanupTemporaryAudioFiles()
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
