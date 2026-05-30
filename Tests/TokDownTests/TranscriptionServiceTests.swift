import XCTest
import Speech
@testable import TokDown

final class TranscriptionServiceTests: XCTestCase {
    func testSpeechRecognitionAccessStateMapsAuthorizationStatus() {
        XCTAssertEqual(SpeechRecognitionAccessState(status: .authorized), .authorized)
        XCTAssertEqual(SpeechRecognitionAccessState(status: .denied), .denied)
        XCTAssertEqual(SpeechRecognitionAccessState(status: .restricted), .restricted)
        XCTAssertEqual(SpeechRecognitionAccessState(status: .notDetermined), .notDetermined)
    }

    func testSpeechRecognitionAccessStateFailureMessages() {
        XCTAssertNil(SpeechRecognitionAccessState.authorized.failureMessage)
        XCTAssertEqual(
            SpeechRecognitionAccessState.denied.failureMessage,
            "Speech recognition permission denied. Enable it in System Settings to transcribe recordings."
        )
        XCTAssertEqual(
            SpeechRecognitionAccessState.restricted.failureMessage,
            "Speech recognition is restricted on this Mac."
        )
        XCTAssertEqual(
            SpeechRecognitionAccessState.notDetermined.failureMessage,
            "Speech recognition permission is required before recording can start."
        )
    }

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
