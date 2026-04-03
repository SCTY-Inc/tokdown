import Foundation
import AVFoundation
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
    @Published var recentTranscripts: [RecentTranscript] = []

    let ble: PendantBLE
    let transcription: TranscriptionService
    private let formatter: TranscriptFormatter
    private let github: GitHubSync
    let calendar: CalendarService
    var settings: SettingsStore

    private var opusDecoder: OpusStreamDecoder?
    private var audioSubscription: AnyCancellable?
    private var bleStateSubscription: AnyCancellable?
    private var elapsedTimer: Timer?
    private var calendarCheckTimer: Timer?
    private var disconnectGraceTimer: Timer?
    private var recordingStart: Date?
    private var currentMeeting: CalendarService.Meeting?

    struct RecentTranscript: Identifiable {
        let id = UUID()
        let title: String
        let date: Date
        let pushed: Bool
        let fileURL: URL?
    }

    init(
        ble: PendantBLE,
        transcription: TranscriptionService,
        formatter: TranscriptFormatter = TranscriptFormatter(),
        github: GitHubSync = GitHubSync(),
        calendar: CalendarService,
        settings: SettingsStore
    ) {
        self.ble = ble
        self.transcription = transcription
        self.formatter = formatter
        self.github = github
        self.calendar = calendar
        self.settings = settings
        self.recordingMode = settings.recordingMode
    }

    func applySettings() {
        setRecordingMode(settings.recordingMode)
    }

    func setRecordingMode(_ mode: RecordingMode) {
        recordingMode = mode
        if settings.recordingMode != mode {
            settings.recordingMode = mode
        }

        switch mode {
        case .manual:
            disableCalendarMode()
        case .calendar:
            if calendar.isAuthorized {
                enableCalendarMode()
            }
        }
    }

    func startRecording(meeting: CalendarService.Meeting? = nil) {
        guard state == .idle else { return }

        state = .recording
        recordingStart = Date()
        recordingDuration = 0
        lastError = nil
        currentMeeting = meeting
        currentTitle = meeting?.title ?? ""

        // Activate audio session for background recording
        activateAudioSession()

        opusDecoder = OpusStreamDecoder()
        if opusDecoder == nil {
            lastError = "Opus decoder init failed — audio won't transcribe"
        }
        transcription.startTranscription()

        audioSubscription = ble.opusFrames
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.processOpusFrame(frame)
            }

        // Monitor BLE disconnection during recording
        startBLEMonitoring()

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

    func stopRecording() {
        guard state == .recording else { return }

        audioSubscription?.cancel()
        audioSubscription = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        let endTime = Date()
        let startTime = recordingStart ?? endTime
        let title = currentTitle
        let meeting = currentMeeting

        state = .transcribing

        Task { @MainActor in
            let snapshot = await transcription.finishTranscription()
            let doc = formatter.makeDocument(
                title: title,
                startTime: startTime,
                endTime: endTime,
                meeting: meeting,
                fullText: snapshot.fullText,
                lines: snapshot.lines
            )

            var savedURL: URL?
            do {
                savedURL = try saveTranscriptLocally(doc)
            } catch {
                lastError = "Local save failed: \(error.localizedDescription)"
            }

            if settings.autoPushEnabled {
                state = .pushing
                await pushTranscript(doc: doc, startTime: startTime, fileURL: savedURL)
            } else {
                addRecentTranscript(title: doc.title, date: startTime, pushed: false, fileURL: savedURL)
                resetToIdle()
            }
        }
    }

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

    func disableCalendarMode() {
        calendarCheckTimer?.invalidate()
        calendarCheckTimer = nil
    }

    private var decodedFrameCount = 0
    private var decodeFailCount = 0

    private func processOpusFrame(_ frame: Data) {
        guard let samples = opusDecoder?.decode(opusFrame: frame) else {
            decodeFailCount += 1
            DebugLog.write("opus decode FAIL #\(decodeFailCount) frameLen=\(frame.count) decoder=\(opusDecoder != nil)")
            return
        }
        decodedFrameCount += 1
        DebugLog.write("decoded #\(decodedFrameCount) samples=\(samples.count)")
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

    private func pushTranscript(
        doc: TranscriptFormatter.TranscriptDocument,
        startTime: Date,
        fileURL: URL? = nil
    ) async {
        do {
            try await github.push(
                filename: doc.filename,
                content: doc.markdown,
                commitMessage: "transcript: \(doc.title)"
            )
            addRecentTranscript(title: doc.title, date: startTime, pushed: true, fileURL: fileURL)
        } catch {
            lastError = "Push failed: \(error.localizedDescription)"
            addRecentTranscript(title: doc.title, date: startTime, pushed: false, fileURL: fileURL)
        }
        resetToIdle()
    }

    private func addRecentTranscript(title: String, date: Date, pushed: Bool, fileURL: URL? = nil) {
        recentTranscripts.insert(
            RecentTranscript(title: title, date: date, pushed: pushed, fileURL: fileURL),
            at: 0
        )
    }

    @discardableResult
    private func saveTranscriptLocally(_ doc: TranscriptFormatter.TranscriptDocument) throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let transcriptsURL = documentsURL.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: transcriptsURL,
            withIntermediateDirectories: true
        )
        let fileURL = transcriptsURL.appendingPathComponent(doc.filename)
        try doc.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func resetToIdle() {
        state = .idle
        currentTitle = ""
        recordingDuration = 0
        recordingStart = nil
        currentMeeting = nil
        bleStateSubscription = nil
        disconnectGraceTimer?.invalidate()
        disconnectGraceTimer = nil
        deactivateAudioSession()
    }

    // MARK: - Background Audio Session

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .mixWithOthers])
            try session.setActive(true)
        } catch {
            DebugLog.write("AVAudioSession activate failed: \(error)")
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - BLE Disconnect Handling

    private func startBLEMonitoring() {
        bleStateSubscription = ble.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self, self.state == .recording else { return }

                if newState == .disconnected {
                    // Start grace period — pendant may reconnect
                    self.disconnectGraceTimer?.invalidate()
                    self.disconnectGraceTimer = Timer.scheduledTimer(
                        withTimeInterval: 10,
                        repeats: false
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.state == .recording else { return }
                            self.lastError = "Pendant disconnected — recording stopped"
                            self.stopRecording()
                        }
                    }
                } else if newState == .connected {
                    // Reconnected within grace period
                    self.disconnectGraceTimer?.invalidate()
                    self.disconnectGraceTimer = nil
                    self.opusDecoder?.reset()
                }
            }
    }

    // MARK: - Load Transcripts from Disk

    func loadRecentTranscripts() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let transcriptsDir = docs.appendingPathComponent("Transcripts", isDirectory: true)

        guard let files = try? fm.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let mdFiles = files
            .filter { $0.pathExtension == "md" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA > dateB
            }
            .prefix(50)

        var loaded: [RecentTranscript] = []
        for file in mdFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let title = parseYAMLField("title", from: content) ?? file.deletingPathExtension().lastPathComponent
            let dateStr = parseYAMLField("recording_started_at", from: content)
            let date = dateStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let hasContent = !content.contains("(No transcript)")

            loaded.append(RecentTranscript(
                title: title,
                date: date,
                pushed: false, // TODO: track in index file
                fileURL: file
            ))
            _ = hasContent // suppress unused warning
        }

        recentTranscripts = loaded
    }

    private func parseYAMLField(_ key: String, from content: String) -> String? {
        // Match: key: "value" or key: value
        let pattern = "^\(key):\\s*\"?([^\"\\n]+)\"?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[range])
    }
}
