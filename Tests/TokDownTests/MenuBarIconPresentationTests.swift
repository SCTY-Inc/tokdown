import XCTest
@testable import TokDown

final class MenuBarIconPresentationTests: XCTestCase {
    func testIdlePresentationUsesBaseLabelWithoutBadge() {
        let presentation = MenuBarIconPresentation.forState(.idle)

        XCTAssertEqual(presentation.accessibilityLabel, "TokDown")
        XCTAssertEqual(presentation.badge, .none)
    }

    func testRecordingPresentationUsesRecordingBadge() {
        let presentation = MenuBarIconPresentation.forState(.recording)

        XCTAssertEqual(presentation.accessibilityLabel, "TokDown recording")
        XCTAssertEqual(presentation.badge, .recording)
    }

    func testTranscribingPresentationUsesTranscribingBadge() {
        let presentation = MenuBarIconPresentation.forState(.transcribing)

        XCTAssertEqual(presentation.accessibilityLabel, "TokDown transcribing")
        XCTAssertEqual(presentation.badge, .transcribing)
    }
}
