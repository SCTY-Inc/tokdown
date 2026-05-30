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
    private(set) var latestTranscriptURL: URL?
    var statusMessage: String?
    private(set) var statusMessageIsError = true
    /// Live warning shown during recording when a system-audio capture appears silent.
    private(set) var captureWarning: String?

    let settingsStore: SettingsStore

    private let calendarService = CalendarService()
    private let recordingService = RecordingService()
    private let micFallbackRecorder = RecordingService()
    private let systemAudioService = SystemAudioService()
    private let transcriptionService = TranscriptionService()
    private let storageService = StorageService()
    private let transcriptFormatter = TranscriptFormatter()

    private var startTime: Date?
    private var currentMeeting: UpcomingMeeting?
    private var currentAudioSource: AudioSource?
    private var pendingMicFallbackURL: URL?
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
                await startMicFallbackIfEnabled(startTime: now)
            } else {
                try recordingService.startRecording(to: audioURL)
            }

            startTime = now
            activeTitle = label
            currentMeeting = meeting
            currentAudioSource = sessionAudioSource
            captureWarning = nil
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
        captureWarning = nil

        // Stop the parallel mic-fallback capture (if any) regardless of how the primary ends.
        let micFallbackURL = pendingMicFallbackURL != nil ? micFallbackRecorder.stopRecording() : nil
        pendingMicFallbackURL = nil

        let audioURL: URL?
        if systemAudioService.isRecording {
            do {
                audioURL = try await systemAudioService.stopCapture()
            } catch {
                if let micFallbackURL { storageService.deleteFile(micFallbackURL) }
                setStatusMessage(error.localizedDescription)
                resetSessionState()
                await loadMeetings()
                return
            }
        } else {
            audioURL = recordingService.stopRecording()
        }

        guard let audioURL else {
            if let micFallbackURL { storageService.deleteFile(micFallbackURL) }
            setStatusMessage("No audio file.")
            resetSessionState()
            return
        }

        let recordingEndTime = Date()
        state = .transcribing

        if await transcriptionService.modelNeedsDownload() {
            setStatusMessage("Preparing local speech model...", isError: false)
        }

        // Transcribe the primary capture.
        var lines: [TranscriptLine] = []
        var fullText = ""
        var transcriptionSucceeded = false
        var effectiveAudioSource = Self.recordingSessionAudioSource(
            activeSessionAudioSource: currentAudioSource,
            settingsAudioSource: settingsStore.settings.audioSource
        )

        do {
            let result = try await transcriptionService.transcribe(audioURL: audioURL)
            fullText = result.fullText
            lines = result.lines
            transcriptionSucceeded = true
            setStatusMessage(nil)
        } catch {
            setStatusMessage("Transcription: \(error.localizedDescription)")
            fullText = TranscriptFormatter.failedPlaceholder
        }

        // Mic fallback: if the system-audio transcript is empty/placeholder, try the
        // parallel mic recording before giving up. Exactly one audio file survives below.
        var usedAudioURL = audioURL
        if let micFallbackURL {
            let primaryUsable = transcriptionSucceeded && !TranscriptFormatter.isPlaceholder(fullText)
            if !primaryUsable, let micResult = try? await transcriptionService.transcribe(audioURL: micFallbackURL),
               !TranscriptFormatter.isPlaceholder(micResult.fullText) {
                fullText = micResult.fullText
                lines = micResult.lines
                transcriptionSucceeded = true
                effectiveAudioSource = .microphone
                storageService.deleteFile(audioURL)   // discard the silent system capture
                usedAudioURL = micFallbackURL
                setStatusMessage("System audio was silent — used microphone fallback.", isError: false)
            } else {
                storageService.deleteFile(micFallbackURL)  // primary usable, or mic also empty
            }
        }

        // Save transcript.
        var didWriteTranscript = false
        var transcriptURL: URL?
        if let recordingStartTime = startTime {
            let document = transcriptFormatter.makeDocument(
                fallbackTitle: activeTitle,
                startTime: recordingStartTime,
                endTime: recordingEndTime,
                audioSource: effectiveAudioSource,
                meeting: currentMeeting,
                fullText: fullText,
                lines: lines
            )
            do {
                let url = try storageService.transcriptURL(
                    folderBase: settingsStore.saveFolderURL,
                    title: document.title,
                    startTime: recordingStartTime
                )
                try storageService.writeTranscript(document.markdown, to: url)
                didWriteTranscript = true
                transcriptURL = url
                latestTranscriptURL = url
            } catch {
                setStatusMessage("Save failed: \(error.localizedDescription)")
            }
        } else {
            setStatusMessage("Save failed: missing recording start time.")
        }

        // Keep the audio when there is no usable transcript; otherwise delete it.
        if transcriptionSucceeded && !TranscriptFormatter.isPlaceholder(fullText) {
            let cleanupResult = storageService.deleteFile(usedAudioURL)
            let message = Self.finalStatusMessage(
                currentStatusMessage: statusMessage,
                didWriteTranscript: didWriteTranscript,
                cleanupResult: cleanupResult,
                transcriptionSucceeded: transcriptionSucceeded
            )
            if message != statusMessage { setStatusMessage(message) }
        } else {
            let baseName = transcriptURL?.deletingPathExtension().lastPathComponent
                ?? Self.fallbackAudioBaseName(startTime: startTime, title: activeTitle)
            let retained = storageService.retainAudio(
                usedAudioURL,
                baseName: baseName,
                in: settingsStore.saveFolderURL
            )
            setStatusMessage(
                Self.retentionStatusMessage(didWriteTranscript: didWriteTranscript, retainedAudioURL: retained),
                isError: retained == nil
            )
        }

        resetSessionState()

        // Refresh meetings after recording
        await loadMeetings()
    }

    /// Starts a parallel microphone capture so a silent system-audio tap can fall back to
    /// the mic. Best-effort: any failure (permission denied, recorder busy) is non-fatal.
    private func startMicFallbackIfEnabled(startTime: Date) async {
        guard settingsStore.settings.systemAudioMicFallback else { return }
        guard await micFallbackRecorder.requestMicrophonePermission() else { return }
        guard let micURL = try? storageService.temporaryAudioURL(startTime: startTime) else { return }
        do {
            try micFallbackRecorder.startRecording(to: micURL)
            pendingMicFallbackURL = micURL
        } catch {
            pendingMicFallbackURL = nil
        }
    }

    private func resetSessionState() {
        startTime = nil
        activeTitle = nil
        currentMeeting = nil
        currentAudioSource = nil
        pendingMicFallbackURL = nil
        state = .idle
    }

    func openRecordingsFolder() {
        storageService.openFolder(settingsStore.saveFolderURL)
    }

    func openLatestTranscript() {
        guard let latestTranscriptURL else { return }
        storageService.openFile(latestTranscriptURL)
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

                if currentAudioSource == .systemAudio {
                    captureWarning = Self.silenceWarningMessage(
                        elapsedSeconds: elapsedSeconds,
                        hasAudibleSignal: systemAudioService.hasCapturedAudibleSignal(),
                        micFallbackEnabled: settingsStore.settings.systemAudioMicFallback
                    )
                }
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

    /// Grace period before warning that a system-audio capture looks silent. Long enough
    /// to ignore the first second of model warm-up / leading silence, short enough to let
    /// the user fix the output route (or stop) before losing the whole recording.
    nonisolated static let silenceGraceSeconds = 8

    nonisolated static func silenceWarningMessage(
        elapsedSeconds: Int,
        hasAudibleSignal: Bool,
        micFallbackEnabled: Bool
    ) -> String? {
        guard elapsedSeconds >= silenceGraceSeconds, !hasAudibleSignal else { return nil }
        return micFallbackEnabled
            ? "No system audio yet — capturing microphone as fallback. Check output routing in System Settings ▸ Sound."
            : "No system audio detected — check output routing in System Settings ▸ Sound, or record Microphone instead."
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
