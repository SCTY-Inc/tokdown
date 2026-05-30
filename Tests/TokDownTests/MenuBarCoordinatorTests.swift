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
                currentStatusMessage: "Saved transcript, but failed to delete temporary audio: permissions"
            ),
            "Saved transcript, but failed to delete temporary audio: permissions"
        )
    }

    func testMeetingsStatusMessagePreservesNonCalendarMessageWhenAccessDenied() {
        XCTAssertEqual(
            MenuBarCoordinator.meetingsStatusMessage(
                for: .denied,
                currentStatusMessage: "Transcription failed. Temporary audio was deleted."
            ),
            "Transcription failed. Temporary audio was deleted."
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
            "Saved transcript, but failed to delete temporary audio: busy"
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
            "Transcription failed. Temporary audio was deleted."
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

    // MARK: - Silence warning

    func testSilenceWarningSuppressedDuringGracePeriod() {
        XCTAssertNil(
            MenuBarCoordinator.silenceWarningMessage(
                elapsedSeconds: MenuBarCoordinator.silenceGraceSeconds - 1,
                hasAudibleSignal: false,
                micFallbackEnabled: false
            )
        )
    }

    func testSilenceWarningSuppressedWhenAudibleSignalPresent() {
        XCTAssertNil(
            MenuBarCoordinator.silenceWarningMessage(
                elapsedSeconds: 60,
                hasAudibleSignal: true,
                micFallbackEnabled: false
            )
        )
    }

    func testSilenceWarningSuggestsMicrophoneWhenNoFallback() {
        let message = MenuBarCoordinator.silenceWarningMessage(
            elapsedSeconds: MenuBarCoordinator.silenceGraceSeconds,
            hasAudibleSignal: false,
            micFallbackEnabled: false
        )
        XCTAssertEqual(
            message,
            "No system audio detected — check output routing in System Settings ▸ Sound, or record Microphone instead."
        )
    }

    func testSilenceWarningMentionsFallbackWhenEnabled() {
        let message = MenuBarCoordinator.silenceWarningMessage(
            elapsedSeconds: MenuBarCoordinator.silenceGraceSeconds,
            hasAudibleSignal: false,
            micFallbackEnabled: true
        )
        XCTAssertEqual(message?.contains("fallback"), true)
    }

    // MARK: - Audio retention

    func testRetentionMessageReportsKeptAudioWithTranscript() {
        let url = URL(fileURLWithPath: "/tmp/Transcripts/2026-05-30_14-50_Syra.m4a")
        XCTAssertEqual(
            MenuBarCoordinator.retentionStatusMessage(didWriteTranscript: true, retainedAudioURL: url),
            "Empty transcript — kept audio as 2026-05-30_14-50_Syra.m4a to re-transcribe or listen back."
        )
    }

    func testRetentionMessageReportsKeptAudioWithoutTranscript() {
        let url = URL(fileURLWithPath: "/tmp/Transcripts/clip.m4a")
        XCTAssertEqual(
            MenuBarCoordinator.retentionStatusMessage(didWriteTranscript: false, retainedAudioURL: url),
            "No transcript saved — kept audio as clip.m4a."
        )
    }

    func testRetentionMessageReportsFailureToKeepAudio() {
        XCTAssertEqual(
            MenuBarCoordinator.retentionStatusMessage(didWriteTranscript: true, retainedAudioURL: nil),
            "Empty transcript; failed to keep the audio file."
        )
    }

    func testFallbackAudioBaseNameSanitizesTitle() {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 30
        components.hour = 14
        components.minute = 50
        let date = Calendar(identifier: .gregorian).date(from: components)!

        let base = MenuBarCoordinator.fallbackAudioBaseName(startTime: date, title: "A/B: Meeting")
        XCTAssertEqual(base, "2026-05-30_14-50_A_B_ Meeting")
    }
}
