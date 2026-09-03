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
    private let meetingMicrophoneRecorder = RecordingService()
    private let systemAudioService = SystemAudioService()
    private let audioMixingService = AudioMixingService()
    private let transcriptionService = TranscriptionService()
    private let storageService = StorageService()
    private let transcriptFormatter = TranscriptFormatter()

    private var startTime: Date?
    private var currentMeeting: UpcomingMeeting?
    private var currentAudioSource: AudioSource?
    private var pendingPrimaryAudioURL: URL?
    private var pendingMeetingMicrophoneURL: URL?
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

        let microphoneRecorder = useSystemAudio ? meetingMicrophoneRecorder : recordingService
        guard await microphoneRecorder.requestMicrophonePermission() else {
            let message = useSystemAudio
                ? "Microphone permission denied. Meeting Audio needs it to record you."
                : "Microphone permission denied."
            setStatusMessage(message)
            return
        }

        var pendingAudioURL: URL?
        do {
            let now = Date()
            let audioURL = try storageService.temporaryAudioURL(startTime: now)
            pendingAudioURL = audioURL

            if useSystemAudio {
                try await systemAudioService.startCapture(to: audioURL)
                do {
                    let microphoneURL = try storageService.temporaryAudioURL(startTime: now)
                    try meetingMicrophoneRecorder.startRecording(to: microphoneURL)
                    pendingMeetingMicrophoneURL = microphoneURL
                } catch {
                    _ = try? await systemAudioService.stopCapture()
                    throw error
                }
            } else {
                try recordingService.startRecording(to: audioURL)
            }

            pendingPrimaryAudioURL = audioURL
            startTime = Date()
            activeTitle = label
            currentMeeting = meeting
            currentAudioSource = sessionAudioSource
            captureWarning = nil
            state = .recording
            elapsedSeconds = 0
            startElapsedTimer()
        } catch {
            if pendingMeetingMicrophoneURL != nil,
               let microphoneURL = meetingMicrophoneRecorder.stopRecording() {
                storageService.deleteFile(microphoneURL)
            }
            pendingMeetingMicrophoneURL = nil
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

        let microphoneURL = pendingMeetingMicrophoneURL != nil
            ? meetingMicrophoneRecorder.stopRecording()
            : nil
        pendingMeetingMicrophoneURL = nil
        let sessionPrimaryAudioURL = pendingPrimaryAudioURL
        pendingPrimaryAudioURL = nil

        var effectiveAudioSource = Self.recordingSessionAudioSource(
            activeSessionAudioSource: currentAudioSource,
            settingsAudioSource: settingsStore.settings.audioSource
        )
        var captureCompletionMessage: String?
        let primaryAudioURL: URL?
        if systemAudioService.isRecording {
            do {
                primaryAudioURL = try await systemAudioService.stopCapture()
            } catch {
                let retainedSystemAudio = retainMeetingAudioFiles(
                    systemAudioURL: sessionPrimaryAudioURL,
                    microphoneURL: nil
                )
                let recoverySuffix = retainedSystemAudio.isEmpty
                    ? ""
                    : " Kept the partial system recording for recovery."
                if let microphoneURL {
                    primaryAudioURL = microphoneURL
                    effectiveAudioSource = .microphone
                    captureCompletionMessage = "System audio failed; transcript contains microphone audio only: \(error.localizedDescription)\(recoverySuffix)"
                } else {
                    setStatusMessage("Meeting recording failed: \(error.localizedDescription)\(recoverySuffix)")
                    resetSessionState()
                    await loadMeetings()
                    return
                }
            }
        } else {
            primaryAudioURL = recordingService.stopRecording()
        }

        guard let primaryAudioURL else {
            let retained = retainMeetingAudioFiles(systemAudioURL: nil, microphoneURL: microphoneURL)
            let suffix = retained.isEmpty ? "" : " Kept the microphone recording for recovery."
            setStatusMessage("No primary audio file.\(suffix)")
            resetSessionState()
            return
        }

        var audioURL = primaryAudioURL
        var componentCleanupFailure: String?

        if effectiveAudioSource == .systemAudio {
            guard let microphoneURL else {
                let retained = retainMeetingAudioFiles(systemAudioURL: primaryAudioURL, microphoneURL: nil)
                let suffix = retained.isEmpty ? "" : " Kept the system recording for recovery."
                setStatusMessage("Meeting recording incomplete: no microphone audio was captured.\(suffix)")
                resetSessionState()
                await loadMeetings()
                return
            }

            var mixedAudioURL: URL?
            do {
                setStatusMessage("Combining meeting audio...", isError: false)
                let outputURL = try storageService.temporaryAudioURL(startTime: startTime ?? Date())
                mixedAudioURL = outputURL
                audioURL = try await audioMixingService.mix(
                    systemAudioURL: primaryAudioURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL
                )

                let cleanupResults = [primaryAudioURL, microphoneURL].map(storageService.deleteFile)
                let failures = cleanupResults.compactMap { result -> String? in
                    guard case .failed(let message) = result else { return nil }
                    return message
                }
                if !failures.isEmpty {
                    componentCleanupFailure = failures.joined(separator: "; ")
                }
            } catch {
                if let mixedAudioURL { storageService.deleteFile(mixedAudioURL) }
                let retained = retainMeetingAudioFiles(
                    systemAudioURL: primaryAudioURL,
                    microphoneURL: microphoneURL
                )
                let suffix = retained.isEmpty
                    ? ""
                    : " Kept both source recordings for recovery."
                setStatusMessage("Could not combine meeting audio: \(error.localizedDescription)\(suffix)")
                resetSessionState()
                await loadMeetings()
                return
            }
        }

        let recordingEndTime = Date()
        state = .transcribing

        if await transcriptionService.modelNeedsDownload() {
            setStatusMessage("Preparing local speech model...", isError: false)
        }

        var lines: [TranscriptLine] = []
        var fullText = ""
        var transcriptionSucceeded = false

        do {
            let result = try await transcriptionService.transcribe(audioURL: audioURL)
            fullText = result.fullText
            lines = result.lines
            transcriptionSucceeded = true
            let cleanupMessage = componentCleanupFailure.map {
                "Combined meeting audio, but failed to delete source audio: \($0)"
            }
            setStatusMessage(cleanupMessage ?? captureCompletionMessage)
        } catch {
            setStatusMessage("Transcription: \(error.localizedDescription)")
            fullText = TranscriptFormatter.failedPlaceholder
        }

        let usedAudioURL = audioURL

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

    private func retainMeetingAudioFiles(systemAudioURL: URL?, microphoneURL: URL?) -> [URL] {
        let baseName = Self.fallbackAudioBaseName(startTime: startTime, title: activeTitle)
        return [
            systemAudioURL.flatMap {
                storageService.retainAudio($0, baseName: "\(baseName)-system", in: settingsStore.saveFolderURL)
            },
            microphoneURL.flatMap {
                storageService.retainAudio($0, baseName: "\(baseName)-microphone", in: settingsStore.saveFolderURL)
            }
        ].compactMap { $0 }
    }

    private func resetSessionState() {
        startTime = nil
        activeTitle = nil
        currentMeeting = nil
        currentAudioSource = nil
        pendingPrimaryAudioURL = nil
        pendingMeetingMicrophoneURL = nil
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
                        hasAudibleSignal: systemAudioService.hasCapturedAudibleSignal()
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
