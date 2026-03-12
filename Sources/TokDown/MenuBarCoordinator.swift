import Foundation
import AppKit

@MainActor
final class MenuBarCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var activeTitle: String?
    @Published private(set) var upcomingMeetings: [UpcomingMeeting] = []
    @Published var statusMessage: String?

    let settingsStore: SettingsStore

    private let calendarService = CalendarService()
    private let recordingService = RecordingService()
    private let systemAudioService = SystemAudioService()
    private let transcriptionService = TranscriptionService()
    private let storageService = StorageService()

    private var startTime: Date?
    private var currentArtifacts: SessionArtifacts?
    private var elapsedTimer: Timer?

    var menuTitle: String {
        state == .recording ? formattedElapsed : ""
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    deinit {
        MainActor.assumeIsolated { elapsedTimer?.invalidate() }
    }

    // MARK: - Meetings

    func loadMeetings() async {
        upcomingMeetings = await calendarService.upcomingMeetings(limit: 5)
    }

    // MARK: - Recording

    func startRecording(title: String? = nil) async {
        guard state == .idle else { return }
        statusMessage = nil

        let label = title ?? "Recording"
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
            currentArtifacts = artifacts
            state = .recording
            elapsedSeconds = 0
            startElapsedTimer()
        } catch {
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
            state = .idle
            return
        }

        state = .transcribing

        // Transcribe
        var lines: [TranscriptLine] = []
        var fullText = ""

        do {
            let result = try await transcriptionService.transcribe(audioURL: audioURL)
            fullText = result.0
            lines = result.1
        } catch {
            statusMessage = "Transcription: \(error.localizedDescription)"
            fullText = "(Transcription failed)"
        }

        // Save transcript
        if let artifacts = currentArtifacts {
            let markdown = buildMarkdown(
                title: activeTitle ?? "Recording",
                startTime: startTime ?? Date(),
                endTime: Date(),
                fullText: fullText,
                lines: lines
            )
            try? storageService.writeTranscript(markdown, to: artifacts.transcriptURL)
        }

        // Always delete audio
        storageService.deleteFile(audioURL)

        // Reset
        startTime = nil
        activeTitle = nil
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
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startTime, self.state == .recording else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedSeconds = 0
    }

    private var formattedElapsed: String {
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        return elapsedSeconds >= 3600
            ? String(format: "%d:%02d:%02d", elapsedSeconds / 3600, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Markdown

    private func buildMarkdown(
        title: String, startTime: Date, endTime: Date,
        fullText: String, lines: [TranscriptLine]
    ) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        // Collapse segments into sentences (group by ~5s windows)
        let body: String
        if lines.isEmpty {
            body = fullText.isEmpty ? "(No transcript)" : fullText
        } else {
            body = collapseSegments(lines)
        }

        return """
        # \(title)

        \(dateFmt.string(from: startTime)) \(timeFmt.string(from: startTime))–\(timeFmt.string(from: endTime))

        \(body)
        """.replacingOccurrences(of: "        ", with: "")
    }

    private func collapseSegments(_ lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return "" }

        var result: [String] = []
        var currentChunk: [String] = []
        var chunkStart = lines[0].timestamp

        for line in lines {
            if line.timestamp - chunkStart > 5, !currentChunk.isEmpty {
                let ts = formatTimestamp(chunkStart)
                result.append("[\(ts)] \(currentChunk.joined(separator: " "))")
                currentChunk = []
                chunkStart = line.timestamp
            }
            currentChunk.append(line.text)
        }

        if !currentChunk.isEmpty {
            let ts = formatTimestamp(chunkStart)
            result.append("[\(ts)] \(currentChunk.joined(separator: " "))")
        }

        return result.joined(separator: "\n\n")
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
