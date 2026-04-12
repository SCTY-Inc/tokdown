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

        XCTAssertEqual(first.audioURL.lastPathComponent, "2026-03-13_14-00_Weekly Sync.m4a")
        XCTAssertEqual(first.transcriptURL.lastPathComponent, "2026-03-13_14-00_Weekly Sync.md")
        XCTAssertEqual(second.audioURL.lastPathComponent, "2026-03-13_14-00_Weekly Sync-2.m4a")
        XCTAssertEqual(second.transcriptURL.lastPathComponent, "2026-03-13_14-00_Weekly Sync-2.md")
    }

    func testTranscriptURLAddsSuffixWithoutChangingDateFirstPrefix() throws {
        let folder = try makeTempFolder()
        let service = StorageService()
        let startTime = date("2026-03-13T14:00:00Z")

        let existing = service.transcriptURL(folderBase: folder, title: "Recording", startTime: startTime)
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        let next = service.transcriptURL(folderBase: folder, title: "Recording", startTime: startTime)

        XCTAssertEqual(existing.lastPathComponent, "2026-03-13_14-00_Recording.md")
        XCTAssertEqual(next.lastPathComponent, "2026-03-13_14-00_Recording-2.md")
        XCTAssertTrue(next.lastPathComponent.hasPrefix("2026-03-13_14-00_"))
    }

    func testDeleteFileReportsSuccessAndFailure() throws {
        let folder = try makeTempFolder()
        let service = StorageService()
        let fileURL = folder.appendingPathComponent("sample.m4a")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("audio".utf8))

        XCTAssertEqual(service.deleteFile(fileURL), .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

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
}
