import XCTest
@testable import TokDown

final class SystemAudioServiceTests: XCTestCase {
    func testNoAudioCapturedErrorDescriptionIsClear() {
        XCTAssertEqual(
            SystemAudioError.noAudioCaptured.localizedDescription,
            "No system audio was captured."
        )
    }

    func testRemovePartialCaptureFileDeletesExistingFile() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let audioURL = tempDirectory.appendingPathComponent("partial.m4a")
        try Data("partial".utf8).write(to: audioURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        SystemAudioService.removePartialCaptureFile(at: audioURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRemovePartialCaptureFileIgnoresMissingFile() {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.m4a")

        XCTAssertNoThrow(SystemAudioService.removePartialCaptureFile(at: audioURL))
    }
}
