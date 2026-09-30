import XCTest
@testable import TokDown

final class TranscriptionServiceTests: XCTestCase {
    func testTranscriptionTimeoutScalesWithDuration() {
        // A 30-minute recording must get well beyond the old fixed 5-min cap.
        XCTAssertEqual(
            TranscriptionService.transcriptionTimeoutSeconds(forDurationSeconds: 30 * 60),
            Int(30 * 60 * 2) + 60
        )
    }

    func testTranscriptionTimeoutEnforcesFiveMinuteFloor() {
        XCTAssertEqual(
            TranscriptionService.transcriptionTimeoutSeconds(forDurationSeconds: 10),
            300
        )
    }

    func testTranscriptionTimeoutUsesLongDefaultForUnknownDuration() {
        XCTAssertEqual(
            TranscriptionService.transcriptionTimeoutSeconds(forDurationSeconds: 0),
            TranscriptionService.unknownDurationTimeoutSeconds
        )
        XCTAssertEqual(
            TranscriptionService.transcriptionTimeoutSeconds(forAudioAt: URL(fileURLWithPath: "/tmp/does-not-exist.m4a")),
            TranscriptionService.unknownDurationTimeoutSeconds
        )
    }
}
