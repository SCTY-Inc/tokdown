import XCTest
@testable import TokDown

final class MenuBarCoordinatorTests: XCTestCase {
    func testMeetingsStatusMessageClearsCalendarWarningsAfterAccessAllowed() {
        XCTAssertNil(
            MenuBarCoordinator.meetingsStatusMessage(
                for: .allowed,
                currentStatusMessage: "Calendar access upgrade required to read upcoming meetings."
            )
        )

        XCTAssertNil(
            MenuBarCoordinator.meetingsStatusMessage(
                for: .allowed,
                currentStatusMessage: "Calendar access denied. Enable Calendar access in System Settings to load upcoming meetings."
            )
        )
    }

    func testMeetingsStatusMessagePreservesNonCalendarMessageWhenAccessAllowed() {
        XCTAssertEqual(
            MenuBarCoordinator.meetingsStatusMessage(
                for: .allowed,
                currentStatusMessage: "Saved transcript, but failed to delete audio: permissions"
            ),
            "Saved transcript, but failed to delete audio: permissions"
        )
    }

    func testMeetingsStatusMessageReturnsClearUpgradeAndDeniedMessages() {
        XCTAssertEqual(
            MenuBarCoordinator.meetingsStatusMessage(
                for: .upgradeRequired,
                currentStatusMessage: nil
            ),
            "Calendar access upgrade required to read upcoming meetings."
        )

        XCTAssertEqual(
            MenuBarCoordinator.meetingsStatusMessage(
                for: .denied,
                currentStatusMessage: nil
            ),
            "Calendar access denied. Enable Calendar access in System Settings to load upcoming meetings."
        )
    }

    func testFinalStatusMessagePrioritizesCleanupFailure() {
        XCTAssertEqual(
            MenuBarCoordinator.finalStatusMessage(
                currentStatusMessage: nil,
                didWriteTranscript: true,
                cleanupResult: .failed("busy"),
                transcriptionSucceeded: true
            ),
            "Saved transcript, but failed to delete audio: busy"
        )

        XCTAssertEqual(
            MenuBarCoordinator.finalStatusMessage(
                currentStatusMessage: "Save failed: disk full",
                didWriteTranscript: false,
                cleanupResult: .failed("missing file"),
                transcriptionSucceeded: false
            ),
            "Cleanup failed: missing file"
        )
    }

    func testFinalStatusMessageReportsDeletedAudioAfterTranscriptionFailure() {
        XCTAssertEqual(
            MenuBarCoordinator.finalStatusMessage(
                currentStatusMessage: nil,
                didWriteTranscript: false,
                cleanupResult: .deleted,
                transcriptionSucceeded: false
            ),
            "Transcription failed. Audio was deleted."
        )
    }

    func testFinalStatusMessagePreservesExistingStatusWhenCleanupSucceeds() {
        XCTAssertEqual(
            MenuBarCoordinator.finalStatusMessage(
                currentStatusMessage: "Save failed: disk full",
                didWriteTranscript: false,
                cleanupResult: .deleted,
                transcriptionSucceeded: true
            ),
            "Save failed: disk full"
        )
    }

    func testRecordingSessionAudioSourcePrefersCapturedSessionValue() {
        XCTAssertEqual(
            MenuBarCoordinator.recordingSessionAudioSource(
                activeSessionAudioSource: .systemAudio,
                settingsAudioSource: .microphone
            ),
            .systemAudio
        )
    }

    func testRecordingSessionAudioSourceFallsBackToCurrentSettingWhenNoSessionValueExists() {
        XCTAssertEqual(
            MenuBarCoordinator.recordingSessionAudioSource(
                activeSessionAudioSource: nil,
                settingsAudioSource: .microphone
            ),
            .microphone
        )
    }
}
