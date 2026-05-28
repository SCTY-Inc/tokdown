import Foundation
import AppKit
import EventKit

@MainActor
@Observable
final class MenuBarCoordinator {
    private(set) var state: RecordingState = .idle
    private(set) var elapsedSeconds: Int = 0
    private(set) var activeTitle: String?
    private(set) var upcomingMeetings: [UpcomingMeeting] = []
    var statusMessage: String?
    private(set) var statusMessageIsError = true

    let settingsStore: SettingsStore

    private let calendarService = CalendarService()
    private let recordingService = RecordingService()
    private let systemAudioService = SystemAudioService()
    private let transcriptionService = TranscriptionService()
    private let storageService = StorageService()
    private let transcriptFormatter = TranscriptFormatter()

    private var startTime: Date?
    private var currentMeeting: UpcomingMeeting?
    private var currentAudioSource: AudioSource?
    private var timerTask: Task<Void, Never>?
    private var isHandlingRecordingAction = false
    @ObservationIgnored private var calendarChangeObserver: NSObjectProtocol?

    var menuTitle: String {
        state == .recording ? formattedElapsed : ""
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        calendarChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .idle else { return }
                await self.loadMeetings()
            }
        }
    }

    isolated deinit {
        if let observer = calendarChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Meetings

    func loadMeetings() async {
        storageService.cleanupTemporaryAudioFiles()
        let result = await calendarService.upcomingMeetings(limit: 3)
        upcomingMeetings = result.meetings
        let updatedStatusMessage = Self.meetingsStatusMessage(
            for: result.accessState,
            currentStatusMessage: statusMessage
        )
        if updatedStatusMessage != statusMessage {
            setStatusMessage(updatedStatusMessage)
        }
    }

    // MARK: - Recording

    func startRecording(meeting: UpcomingMeeting? = nil) async {
        guard state == .idle, !isHandlingRecordingAction else { return }
        isHandlingRecordingAction = true
        defer { isHandlingRecordingAction = false }
        setStatusMessage(nil)

        let speechAccessState = await transcriptionService.speechRecognitionAccessState(requestingIfNeeded: true)
        guard speechAccessState == .authorized else {
            setStatusMessage(speechAccessState.failureMessage)
            return
        }

        let sessionAudioSource = settingsStore.settings.audioSource
        let label = meeting?.title ?? sessionAudioSource.title
        let useSystemAudio = sessionAudioSource == .systemAudio

        if await transcriptionService.modelNeedsDownload() {
            setStatusMessage("Preparing local speech model...", isError: false)
        }

        do {
            try await transcriptionService.ensureModelAvailable()
        } catch {
            setStatusMessage("Speech model unavailable: \(error.localizedDescription)")
            return
        }

        setStatusMessage(nil)

        if !useSystemAudio {
            guard await recordingService.requestMicrophonePermission() else {
                setStatusMessage("Microphone permission denied.")
                return
            }
        }

        var pendingAudioURL: URL?
        do {
            let now = Date()
            let audioURL = try storageService.temporaryAudioURL(startTime: now)
            pendingAudioURL = audioURL

            if useSystemAudio {
                try await systemAudioService.startCapture(to: audioURL)
            } else {
                try recordingService.startRecording(to: audioURL)
            }

            startTime = now
            activeTitle = label
            currentMeeting = meeting
            currentAudioSource = sessionAudioSource
            state = .recording
            elapsedSeconds = 0
            startElapsedTimer()
        } catch {
            if let pendingAudioURL {
                storageService.deleteFile(pendingAudioURL)
            }
            currentMeeting = nil
            setStatusMessage("Failed: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard state == .recording, !isHandlingRecordingAction else { return }
        isHandlingRecordingAction = true
        defer { isHandlingRecordingAction = false }
        stopElapsedTimer()

        let audioURL: URL?
        if systemAudioService.isRecording {
            do {
                audioURL = try await systemAudioService.stopCapture()
            } catch {
                setStatusMessage(error.localizedDescription)
                startTime = nil
                activeTitle = nil
                currentMeeting = nil
                currentAudioSource = nil
                state = .idle
                await loadMeetings()
                return
            }
        } else {
            audioURL = recordingService.stopRecording()
        }

        guard let audioURL else {
            setStatusMessage("No audio file.")
            startTime = nil
            activeTitle = nil
            currentMeeting = nil
            currentAudioSource = nil
            state = .idle
            return
        }

        let recordingEndTime = Date()
        state = .transcribing

        if await transcriptionService.modelNeedsDownload() {
            setStatusMessage("Preparing local speech model...", isError: false)
        }

        // Transcribe
        var lines: [TranscriptLine] = []
        var fullText = ""
        var transcriptionSucceeded = false

        do {
            let result = try await transcriptionService.transcribe(audioURL: audioURL)
            fullText = result.fullText
            lines = result.lines
            transcriptionSucceeded = true
            setStatusMessage(nil)
        } catch {
            setStatusMessage("Transcription: \(error.localizedDescription)")
            fullText = "(Transcription failed)"
        }

        // Save transcript
        var didWriteTranscript = false
        if let recordingStartTime = startTime {
            let document = transcriptFormatter.makeDocument(
                fallbackTitle: activeTitle,
                startTime: recordingStartTime,
                endTime: recordingEndTime,
                audioSource: Self.recordingSessionAudioSource(
                    activeSessionAudioSource: currentAudioSource,
                    settingsAudioSource: settingsStore.settings.audioSource
                ),
                meeting: currentMeeting,
                fullText: fullText,
                lines: lines
            )
            do {
                let transcriptURL = try storageService.transcriptURL(
                    folderBase: settingsStore.saveFolderURL,
                    title: document.title,
                    startTime: recordingStartTime
                )
                try storageService.writeTranscript(document.markdown, to: transcriptURL)
                didWriteTranscript = true
            } catch {
                setStatusMessage("Save failed: \(error.localizedDescription)")
            }
        } else {
            setStatusMessage("Save failed: missing recording start time.")
        }

        let cleanupResult = storageService.deleteFile(audioURL)
        let finalStatusMessage = Self.finalStatusMessage(
            currentStatusMessage: statusMessage,
            didWriteTranscript: didWriteTranscript,
            cleanupResult: cleanupResult,
            transcriptionSucceeded: transcriptionSucceeded
        )
        if finalStatusMessage != statusMessage {
            setStatusMessage(finalStatusMessage)
        }

        // Reset
        startTime = nil
        activeTitle = nil
        currentMeeting = nil
        currentAudioSource = nil
        state = .idle

        // Refresh meetings after recording
        await loadMeetings()
    }

    func openRecordingsFolder() {
        storageService.openFolder(settingsStore.saveFolderURL)
    }

    private func setStatusMessage(_ message: String?, isError: Bool = true) {
        statusMessage = message
        statusMessageIsError = message == nil ? true : isError
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
}
