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
}
