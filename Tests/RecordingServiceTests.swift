import XCTest
import AVFoundation
@testable import TokDown

final class RecordingServiceTests: XCTestCase {
    func testMicrophoneAccessGrantedMapsAuthorizedToTrue() {
        XCTAssertEqual(RecordingService.microphoneAccessGranted(for: .authorized), true)
    }

    func testMicrophoneAccessGrantedMapsDeniedToFalse() {
        XCTAssertEqual(RecordingService.microphoneAccessGranted(for: .denied), false)
    }

    func testMicrophoneAccessGrantedMapsRestrictedToFalse() {
        XCTAssertEqual(RecordingService.microphoneAccessGranted(for: .restricted), false)
    }

    func testMicrophoneAccessGrantedMapsNotDeterminedToNil() {
        XCTAssertNil(RecordingService.microphoneAccessGranted(for: .notDetermined))
    }
}
