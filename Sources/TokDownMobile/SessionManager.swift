import Foundation
import Combine

/// Orchestrates the full pipeline: BLE audio -> decode -> transcribe -> format -> push.
///
/// States: idle -> recording -> transcribing -> pushing -> idle
/// Modes:
///   - Manual: user taps start/stop
///   - Calendar: auto-start when meeting begins, auto-stop when meeting ends
@MainActor
final class SessionManager: ObservableObject {

    enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case pushing
    }

    enum RecordingMode: String, CaseIterable, Sendable {
        case manual
        case calendar
    }

    @Published var state: State = .idle
    @Published var recordingMode: RecordingMode = .manual
    @Published var currentTitle: String = ""
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastError: String?

    let ble: PendantBLE
    private let decoder: AudioPacketProcessor
    let transcription: TranscriptionService
    private let formatter: TranscriptFormatter
    private let github: GitHubSync
    let calendar: CalendarService
    let settings: SettingsStore

    private var audioSubscription: AnyCancellable?
    private var elapsedTimer: Timer?
    private var calendarCheckTimer: Timer?
    private var recordingStart: Date?
    private var currentMeeting: CalendarService.Meeting?

    /// Recently completed transcript filenames for the "Recent" list
    @Published var recentTranscripts: [RecentTranscript] = []

    struct RecentTranscript: Identifiable {
        let id = UUID()
        let title: String
        let date: Date
        let pushed: Bool
    }

    init(
        ble: PendantBLE,
        decoder: AudioPacketProcessor = AudioPacketProcessor(),
        transcription: TranscriptionService,
        formatter: TranscriptFormatter = TranscriptFormatter(),
        github: GitHubSync = GitHubSync(),
        calendar: CalendarService,
        settings: SettingsStore
    ) {
        self.ble = ble
        self.decoder = decoder
        self.transcription = transcription
        self.formatter = formatter
        self.github = github
        self.calendar = calendar
        self.settings = settings
    }

    /// Start a recording session.
    /// - Parameter meeting: Optional calendar meeting to associate
    func startRecording(meeting: CalendarService.Meeting? = nil) {
        guard state == .idle else { return }

        state = .recording
        recordingStart = Date()
        recordingDuration = 0
        lastError = nil
        currentMeeting = meeting

        if let meeting {
            currentTitle = meeting.title
        } else {
            currentTitle = ""
        }

        decoder.reset()
        transcription.startTranscription()

        audioSubscription = ble.audioPackets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.processAudioPacket(data)
            }

        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStart else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    /// Stop recording and begin transcription finalization + push.
    func stopRecording() {
        guard state == .recording else { return }

        audioSubscription?.cancel()
        audioSubscription = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        state = .transcribing
        transcription.stopTranscription()

        let endTime = Date()
        let startTime = recordingStart ?? endTime

        let doc = formatter.makeDocument(
            title: currentTitle,
            startTime: startTime,
            endTime: endTime,
            meeting: currentMeeting,
            fullText: transcription.fullText,
            lines: transcription.lines
        )

        if settings.autoPushEnabled {
            state = .pushing
            Task {
                await pushTranscript(doc: doc)
            }
        } else {
            let recent = RecentTranscript(
                title: doc.title,
                date: startTime,
                pushed: false
            )
            recentTranscripts.insert(recent, at: 0)
            resetToIdle()
        }
    }

    /// Enable calendar-based auto-recording.
    /// Checks every 30s if a meeting has started or ended.
    func enableCalendarMode() {
        recordingMode = .calendar
        calendar.refreshMeetings()

        calendarCheckTimer?.invalidate()
        calendarCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCalendarState()
            }
        }
    }

    /// Disable calendar-based auto-recording.
    func disableCalendarMode() {
        calendarCheckTimer?.invalidate()
        calendarCheckTimer = nil
    }

    // MARK: - Private

    private func processAudioPacket(_ data: Data) {
        guard let samples = decoder.process(packet: data) else { return }
        transcription.appendAudio(samples: samples)
    }

    private func checkCalendarState() {
        calendar.refreshMeetings()

        if let meeting = calendar.currentMeeting() {
            if state == .idle {
                startRecording(meeting: meeting)
            }
        } else if state == .recording, currentMeeting != nil {
            stopRecording()
        }
    }

    private func pushTranscript(doc: TranscriptFormatter.TranscriptDocument) async {
        do {
            try await github.push(
                filename: doc.filename,
                content: doc.markdown,
                commitMessage: "transcript: \(doc.title)"
            )
            let recent = RecentTranscript(
                title: doc.title,
                date: recordingStart ?? Date(),
                pushed: true
            )
            recentTranscripts.insert(recent, at: 0)
        } catch {
            lastError = "Push failed: \(error.localizedDescription)"
        }
        resetToIdle()
    }

    private func resetToIdle() {
        state = .idle
        currentTitle = ""
        recordingDuration = 0
        recordingStart = nil
        currentMeeting = nil
    }
}
