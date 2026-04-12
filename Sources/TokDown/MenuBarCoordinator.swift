import Foundation
import AppKit

@MainActor
@Observable
final class MenuBarCoordinator {
    private(set) var state: RecordingState = .idle
    private(set) var elapsedSeconds: Int = 0
    private(set) var activeTitle: String?
    private(set) var upcomingMeetings: [UpcomingMeeting] = []
    var statusMessage: String?

    let settingsStore: SettingsStore

    private let calendarService = CalendarService()
    private let recordingService = RecordingService()
    private let systemAudioService = SystemAudioService()
    private let transcriptionService = TranscriptionService()
    private let storageService = StorageService()
    private let transcriptFormatter = TranscriptFormatter()

    private var startTime: Date?
    private var currentMeeting: UpcomingMeeting?
    private var currentArtifacts: SessionArtifacts?
    private var timerTask: Task<Void, Never>?

    var menuTitle: String {
        state == .recording ? formattedElapsed : ""
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    // MARK: - Meetings

    func loadMeetings() async {
        let result = await calendarService.upcomingMeetings(limit: 3)
        upcomingMeetings = result.meetings

        switch result.accessState {
        case .allowed:
            if statusMessage == "Calendar access upgrade required to read upcoming meetings." {
                statusMessage = nil
            }
        case .upgradeRequired:
            statusMessage = "Calendar access upgrade required to read upcoming meetings."
        case .denied:
            break
        }
    }

    // MARK: - Recording

    func startRecording(meeting: UpcomingMeeting? = nil) async {
        guard state == .idle else { return }
        statusMessage = nil

        let speechAccessState = await transcriptionService.speechRecognitionAccessState(requestingIfNeeded: true)
        guard speechAccessState == .authorized else {
            statusMessage = speechAccessState.failureMessage
            return
        }

        let label = meeting?.title ?? settingsStore.settings.audioSource.title
        let useSystemAudio = settingsStore.settings.audioSource == .systemAudio

        if !useSystemAudio {
            guard await recordingService.requestMicrophonePermission() else {
                statusMessage = "Microphone permission denied."
                return
            }
        }

        do {
            let now = Date()
            let artifacts = try storageService.sessionArtifacts(
                folderBase: settingsStore.saveFolderURL,
                title: label,
                startTime: now
            )

            if useSystemAudio {
                try await systemAudioService.startCapture(to: artifacts.audioURL)
            } else {
                try recordingService.startRecording(to: artifacts.audioURL)
            }

            startTime = now
            activeTitle = label
            currentMeeting = meeting
            currentArtifacts = artifacts
            state = .recording
            elapsedSeconds = 0
            startElapsedTimer()
        } catch {
            currentMeeting = nil
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        stopElapsedTimer()

        let audioURL: URL?
        if systemAudioService.isRecording {
            audioURL = await systemAudioService.stopCapture()
        } else {
            audioURL = recordingService.stopRecording()
        }

        guard let audioURL else {
            statusMessage = "No audio file."
            startTime = nil
            activeTitle = nil
            currentMeeting = nil
            currentArtifacts = nil
            state = .idle
            return
        }

        let recordingEndTime = Date()
        state = .transcribing

        // Transcribe
        var lines: [TranscriptLine] = []
        var fullText = ""
        var transcriptionSucceeded = false

        do {
            let result = try await transcriptionService.transcribe(audioURL: audioURL)
            fullText = result.fullText
            lines = result.lines
            transcriptionSucceeded = true
        } catch {
            statusMessage = "Transcription: \(error.localizedDescription)"
            fullText = "(Transcription failed)"
        }

        // Save transcript
        var didWriteTranscript = false
        if let artifacts = currentArtifacts, let recordingStartTime = startTime {
            let document = transcriptFormatter.makeDocument(
                fallbackTitle: activeTitle,
                startTime: recordingStartTime,
                endTime: recordingEndTime,
                audioSource: settingsStore.settings.audioSource,
                meeting: currentMeeting,
                fullText: fullText,
                lines: lines
            )
            let transcriptURL = storageService.transcriptURL(
                folderBase: artifacts.transcriptURL.deletingLastPathComponent(),
                title: document.title,
                startTime: recordingStartTime
            )
            do {
                try storageService.writeTranscript(document.markdown, to: transcriptURL)
                didWriteTranscript = true
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        } else {
            statusMessage = "Save failed: missing session artifacts."
        }

        let cleanupResult = storageService.deleteFile(audioURL)

        if case let .failed(message) = cleanupResult {
            statusMessage = didWriteTranscript
                ? "Saved transcript, but failed to delete audio: \(message)"
                : "Cleanup failed: \(message)"
        } else if !transcriptionSucceeded && statusMessage == nil {
            statusMessage = "Transcription failed. Audio was deleted."
        }

        // Reset
        startTime = nil
        activeTitle = nil
        currentMeeting = nil
        currentArtifacts = nil
        state = .idle

        // Refresh meetings after recording
        await loadMeetings()
    }

    func openRecordingsFolder() {
        storageService.openFolder(settingsStore.saveFolderURL)
    }

    // MARK: - Timer

    private func startElapsedTimer() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let start = startTime, state == .recording else { break }
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        timerTask?.cancel()
        timerTask = nil
        elapsedSeconds = 0
    }

    private var formattedElapsed: String {
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        return elapsedSeconds >= 3600
            ? String(format: "%d:%02d:%02d", elapsedSeconds / 3600, m, s)
            : String(format: "%02d:%02d", m, s)
    }

}
