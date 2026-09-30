import Foundation

// Pure status-message and naming helpers, kept apart from the coordinator's state machine.
extension MenuBarCoordinator {
    nonisolated static func meetingsStatusMessage(
        for accessState: CalendarService.CalendarReadAccessState,
        currentStatusMessage: String?
    ) -> String? {
        if let currentStatusMessage,
           !isCalendarStatusMessage(currentStatusMessage) {
            return currentStatusMessage
        }

        switch accessState {
        case .allowed:
            return nil
        case .upgradeRequired:
            return calendarUpgradeMessage
        case .denied:
            return calendarDeniedMessage
        }
    }

    nonisolated private static let calendarUpgradeMessage = "Calendar access upgrade required to read upcoming meetings."
    nonisolated private static let calendarDeniedMessage = "Calendar access denied. Enable Calendar access in System Settings to load upcoming meetings."

    nonisolated private static func isCalendarStatusMessage(_ message: String) -> Bool {
        message == calendarUpgradeMessage || message == calendarDeniedMessage
    }

    nonisolated static func finalStatusMessage(
        currentStatusMessage: String?,
        didWriteTranscript: Bool,
        cleanupResult: FileCleanupResult,
        transcriptionSucceeded: Bool
    ) -> String? {
        switch cleanupResult {
        case let .failed(message):
            return didWriteTranscript
                ? "Saved transcript, but failed to delete temporary audio: \(message)"
                : "Cleanup failed: \(message)"
        case .deleted:
            if !transcriptionSucceeded && currentStatusMessage == nil {
                return "Transcription failed. Temporary audio was deleted."
            }
            return currentStatusMessage
        }
    }

    nonisolated static func recordingSessionAudioSource(
        activeSessionAudioSource: AudioSource?,
        settingsAudioSource: AudioSource
    ) -> AudioSource {
        activeSessionAudioSource ?? settingsAudioSource
    }

    /// Grace period before warning that a system-audio capture looks silent. Long enough
    /// to ignore the first second of model warm-up / leading silence, short enough to let
    /// the user fix the output route (or stop) before losing the whole recording.
    nonisolated static let silenceGraceSeconds = 8

    nonisolated static func silenceWarningMessage(
        elapsedSeconds: Int,
        hasAudibleSignal: Bool
    ) -> String? {
        guard elapsedSeconds >= silenceGraceSeconds, !hasAudibleSignal else { return nil }
        return "No system audio yet — your microphone is still being recorded. Check output routing in System Settings ▸ Sound."
    }

    nonisolated static func retentionStatusMessage(
        didWriteTranscript: Bool,
        retainedAudioURL: URL?
    ) -> String? {
        guard let retainedAudioURL else {
            return didWriteTranscript
                ? "Empty transcript; failed to keep the audio file."
                : "No transcript saved and failed to keep the audio file."
        }
        let name = retainedAudioURL.lastPathComponent
        return didWriteTranscript
            ? "Empty transcript — kept audio as \(name) to re-transcribe or listen back."
            : "No transcript saved — kept audio as \(name)."
    }

    nonisolated static func fallbackAudioBaseName(startTime: Date?, title: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let prefix = formatter.string(from: startTime ?? Date())
        let cleanedTitle = (title ?? "Recording")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:<>*?\"|,\n"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = cleanedTitle.isEmpty ? "Recording" : cleanedTitle
        return "\(prefix)_\(suffix)"
    }
}
