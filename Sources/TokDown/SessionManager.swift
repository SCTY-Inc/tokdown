import Foundation
import AVFoundation
import UIKit
import Observation

enum TranscriptFrontMatter {
    static func value(for key: String, in content: String) -> String? {
        guard let block = block(in: content) else { return nil }

        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let fieldKey = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            guard fieldKey == key else { continue }

            let rawValue = String(line[line.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            return decodeScalar(rawValue)
        }

        return nil
    }

    private static func block(in content: String) -> Substring? {
        guard content.hasPrefix("---\n") else { return nil }
        let start = content.index(content.startIndex, offsetBy: 4)
        guard let end = content.range(of: "\n---", range: start..<content.endIndex)?.lowerBound else {
            return nil
        }
        return content[start..<end]
    }

    private static func decodeScalar(_ rawValue: String) -> String {
        guard rawValue.count >= 2, rawValue.first == "\"", rawValue.last == "\"" else {
            return rawValue
        }

        var decoded = ""
        var isEscaping = false
        for character in rawValue.dropFirst().dropLast() {
            if isEscaping {
                decoded.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                decoded.append(character)
            }
        }
        if isEscaping {
            decoded.append("\\")
        }
        return decoded
    }
}

/// Orchestrates the full pipeline: BLE audio -> decode -> transcribe -> format -> push.
///
/// States: idle -> recording -> transcribing -> pushing -> idle
/// Modes:
///   - Manual: user taps start/stop
///   - Calendar: auto-start when meeting begins, auto-stop when meeting ends
@MainActor @Observable
final class SessionManager {

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

    enum TranscriptionMode: String, CaseIterable, Sendable {
        case live
        case lowPower

        var title: String {
            switch self {
            case .live: "Live"
            case .lowPower: "Low Power"
            }
        }

        var summary: String {
            switch self {
            case .live:
                "Live transcript while recording. Higher battery use."
            case .lowPower:
                "Capture first, transcribe after stop. Best for longer sessions."
            }
        }
    }

    var state: State = .idle
    var recordingMode: RecordingMode = .manual
    var currentTitle: String = ""
    var recordingDuration: TimeInterval = 0
    var lastError: String?
    var recentTranscripts: [RecentTranscript] = []

    var transcriptionMode: TranscriptionMode {
        activeTranscriptionMode ?? settings.transcriptionMode
    }

    var processingStatusText: String {
        switch state {
        case .transcribing:
            switch transcriptionMode {
            case .live: "Finalizing transcript..."
            case .lowPower: "Transcribing saved audio..."
            }
        case .pushing:
            "Pushing to GitHub..."
        default:
            ""
        }
    }

    let ble: PendantBLE
    let transcription: TranscriptionService
    private let formatter: TranscriptFormatter
    let pushQueue: PushQueue
    let calendar: CalendarService
    var settings: SettingsStore

    private var opusDecoder: OpusStreamDecoder?
    private var audioTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var calendarCheckTimer: Timer?
    private var disconnectGraceTimer: Timer?
    private var recordingStart: Date?
    private var currentMeeting: CalendarService.Meeting?
    private var activeTranscriptionMode: TranscriptionMode?
    private var deferredCapture: OpusCaptureFile?

    struct RecentTranscript: Identifiable {
        enum SyncStatus: Sendable {
            case localOnly
            case queued
            case pushed
        }

        let id = UUID()
        let title: String
        let filename: String
        let date: Date
        var syncStatus: SyncStatus
        let fileURL: URL?
    }

    init(
        ble: PendantBLE,
        transcription: TranscriptionService,
        formatter: TranscriptFormatter = TranscriptFormatter(),
        pushQueue: PushQueue = PushQueue(),
        calendar: CalendarService,
        settings: SettingsStore
    ) {
        self.ble = ble
        self.transcription = transcription
        self.formatter = formatter
        self.pushQueue = pushQueue
        self.calendar = calendar
        self.settings = settings
        self.recordingMode = settings.recordingMode
        self.pushQueue.settings = settings
        self.pushQueue.onPushSuccess = { [weak self] item in
            self?.markRecentTranscriptPushed(filename: item.filename)
        }
    }

    func applySettings() {
        setRecordingMode(settings.recordingMode)
    }

    func setRecordingMode(_ mode: RecordingMode) {
        recordingMode = mode

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

        lastError = nil
        currentMeeting = meeting
        currentTitle = meeting?.title ?? ""
        decodedFrameCount = 0
        decodeFailCount = 0
        activeTranscriptionMode = settings.transcriptionMode

        guard prepareRecordingPipeline() else {
            activeTranscriptionMode = nil
            currentMeeting = nil
            currentTitle = ""
            return
        }

        PerformanceTrace.emitEvent("RecordingStart", detail: transcriptionMode.title)
        state = .recording
        recordingStart = Date()
        recordingDuration = 0

        let stream = ble.startOpusStream()
        audioTask = Task { @MainActor [weak self] in
            for await frame in stream {
                self?.processOpusFrame(frame)
            }
        }

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

        audioTask?.cancel()
        audioTask = nil
        ble.stopOpusStream()
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        let endTime = Date()
        let startTime = recordingStart ?? endTime
        let title = currentTitle
        let meeting = currentMeeting

        PerformanceTrace.emitEvent("RecordingStop", detail: transcriptionMode.title)
        state = .transcribing

        let bgTaskID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)

        Task { @MainActor in
            defer {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }

            let signpost = PerformanceTrace.beginInterval("TranscriptBuild", detail: self.transcriptionMode.title)
            let snapshot = await transcribeStoppedRecording()
            PerformanceTrace.endInterval("TranscriptBuild", state: signpost, detail: "chars=\(snapshot.fullText.count)")
            DebugLog.write("snapshot fullTextLen=\(snapshot.fullText.count) lines=\(snapshot.lines.count) decoded=\(self.decodedFrameCount) decodeFails=\(self.decodeFailCount)")

            var resolvedTitle = title
            if resolvedTitle.isEmpty, !snapshot.fullText.isEmpty {
                resolvedTitle = autoTitle(from: snapshot.fullText)
                currentTitle = resolvedTitle
            }

            let doc = formatter.makeDocument(
                title: resolvedTitle,
                startTime: startTime,
                endTime: endTime,
                meeting: meeting,
                fullText: snapshot.fullText,
                lines: snapshot.lines
            )

            var savedURL: URL?
            do {
                savedURL = try saveTranscriptLocally(doc)
                DebugLog.write("saved transcript file=\(doc.filename) markdownLen=\(doc.markdown.count)")
            } catch {
                lastError = "Local save failed: \(error.localizedDescription)"
            }

            if settings.autoPushEnabled {
                pushTranscript(doc: doc, startTime: startTime, fileURL: savedURL)
            } else {
                addRecentTranscript(
                    title: doc.title,
                    filename: doc.filename,
                    date: startTime,
                    syncStatus: .localOnly,
                    fileURL: savedURL
                )
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
        switch transcriptionMode {
        case .live:
            guard let samples = opusDecoder?.decode(opusFrame: frame) else {
                decodeFailCount += 1
                if shouldLogDecodeFailure(count: decodeFailCount) {
                    DebugLog.write("opus decode FAIL #\(decodeFailCount) frameLen=\(frame.count) decoder=\(opusDecoder != nil)")
                }
                return
            }
            decodedFrameCount += 1
            if shouldLogDecodedFrame(count: decodedFrameCount) {
                DebugLog.write("decoded #\(decodedFrameCount) samples=\(samples.count)")
            }
            transcription.appendAudio(samples: samples)

        case .lowPower:
            guard let deferredCapture else {
                lastError = "Low Power capture is unavailable for this recording"
                stopRecording()
                return
            }
            do {
                try deferredCapture.append(frame: frame)
            } catch {
                lastError = "Low Power capture failed: \(error.localizedDescription)"
                stopRecording()
            }
        }
    }

    private func shouldLogDecodedFrame(count: Int) -> Bool {
        count <= 3 || count.isMultiple(of: 50)
    }

    private func shouldLogDecodeFailure(count: Int) -> Bool {
        count <= 5 || count.isMultiple(of: 25)
    }

    private func prepareRecordingPipeline() -> Bool {
        deferredCapture?.delete()
        deferredCapture = nil

        let contextTerms = transcriptionContextTerms()
        transcription.contextualStrings = contextTerms
        transcription.prewarmLanguageModel()

        switch transcriptionMode {
        case .live:
            activateAudioSession()
            opusDecoder = OpusStreamDecoder()
            guard opusDecoder != nil else {
                lastError = "Opus decoder init failed — audio won't transcribe"
                deactivateAudioSession()
                return false
            }

            transcription.startTranscription()

            if let error = transcription.lastError {
                lastError = error
                opusDecoder = nil
                deactivateAudioSession()
                return false
            }
            return true

        case .lowPower:
            opusDecoder = nil
            do {
                deferredCapture = try OpusCaptureFile()
                return true
            } catch {
                lastError = "Couldn't start Low Power capture: \(error.localizedDescription)"
                return false
            }
        }
    }

    private func transcribeStoppedRecording() async -> TranscriptionService.Snapshot {
        switch transcriptionMode {
        case .live:
            return await transcription.finishTranscription()

        case .lowPower:
            return await transcribeDeferredCapture()
        }
    }

    private func transcribeDeferredCapture() async -> TranscriptionService.Snapshot {
        guard let deferredCapture else {
            return .init(fullText: "", lines: [])
        }

        let captureURL: URL
        do {
            captureURL = try deferredCapture.finalize()
        } catch {
            lastError = "Couldn't finalize Low Power capture: \(error.localizedDescription)"
            self.deferredCapture = nil
            return .init(fullText: "", lines: [])
        }
        self.deferredCapture = nil
        var shouldDeleteCapture = false
        defer {
            if shouldDeleteCapture {
                try? FileManager.default.removeItem(at: captureURL)
            }
        }

        guard let decoder = OpusStreamDecoder() else {
            lastError = "Opus decoder init failed — audio won't transcribe"
            preserveDeferredCapture(at: captureURL, reason: lastError ?? "decoder-init")
            return .init(fullText: "", lines: [])
        }

        let renderFile: PCMRenderFile
        do {
            renderFile = try PCMRenderFile()
        } catch {
            lastError = "Couldn't create audio file for Low Power transcription: \(error.localizedDescription)"
            preserveDeferredCapture(at: captureURL, reason: lastError ?? "render-file-init")
            return .init(fullText: "", lines: [])
        }
        defer { renderFile.delete() }

        let signpost = PerformanceTrace.beginInterval("DeferredTranscriptionRender")
        do {
            try OpusCaptureFile.forEachFrame(at: captureURL) { frame in
                guard let samples = decoder.decode(opusFrame: frame) else {
                    decodeFailCount += 1
                    if shouldLogDecodeFailure(count: decodeFailCount) {
                        DebugLog.write("deferred opus decode FAIL #\(decodeFailCount) frameLen=\(frame.count)")
                    }
                    return
                }
                decodedFrameCount += 1
                if shouldLogDecodedFrame(count: decodedFrameCount) {
                    DebugLog.write("deferred decoded #\(decodedFrameCount) samples=\(samples.count)")
                }
                try renderFile.append(samples: samples)
            }
        } catch {
            PerformanceTrace.endInterval("DeferredTranscriptionRender", state: signpost, detail: "failed")
            lastError = "Couldn't render Low Power transcription audio: \(error.localizedDescription)"
            preserveDeferredCapture(at: captureURL, reason: lastError ?? "render-failed")
            return .init(fullText: "", lines: [])
        }
        PerformanceTrace.endInterval("DeferredTranscriptionRender", state: signpost, detail: "frames=\(decodedFrameCount)")

        let snapshot = await transcription.transcribeFile(at: renderFile.url)
        if let error = transcription.lastError {
            lastError = error
        }

        let trimmedText = snapshot.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldPreserveAudio = lastError != nil || (trimmedText.isEmpty && snapshot.lines.isEmpty)
        if shouldPreserveAudio {
            if lastError == nil {
                lastError = "Low Power transcription produced no text"
            }
            preserveDeferredCapture(at: captureURL, reason: lastError ?? "empty-transcript")
        } else {
            shouldDeleteCapture = true
        }

        return snapshot
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
    ) {
        PerformanceTrace.emitEvent("TranscriptQueuedForPush", detail: doc.filename)
        addRecentTranscript(
            title: doc.title,
            filename: doc.filename,
            date: startTime,
            syncStatus: .queued,
            fileURL: fileURL
        )
        pushQueue.enqueue(
            filename: doc.filename,
            content: doc.markdown,
            commitMessage: "transcript: \(doc.title)",
            repo: settings.transcriptRepo,
            basePath: settings.transcriptRepoPath
        )
        resetToIdle()
    }

    func markRecentTranscriptPushed(filename: String) {
        guard let index = recentTranscripts.firstIndex(where: { $0.filename == filename }) else { return }
        recentTranscripts[index].syncStatus = .pushed
    }

    private func addRecentTranscript(
        title: String,
        filename: String,
        date: Date,
        syncStatus: RecentTranscript.SyncStatus,
        fileURL: URL? = nil
    ) {
        recentTranscripts.insert(
            RecentTranscript(
                title: title,
                filename: filename,
                date: date,
                syncStatus: syncStatus,
                fileURL: fileURL
            ),
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
        activeTranscriptionMode = nil
        ble.onConnectionStateChanged = nil
        disconnectGraceTimer?.invalidate()
        disconnectGraceTimer = nil
        deferredCapture?.delete()
        deferredCapture = nil
        opusDecoder = nil
        deactivateAudioSession()
    }

    // MARK: - Auto-Title

    private func autoTitle(from text: String) -> String {
        let words = text.split(separator: " ").prefix(10)
        var title = words.joined(separator: " ")
        if title.count > 60 {
            title = String(title.prefix(57)) + "..."
        }
        return title.isEmpty ? "Pendant Recording" : title
    }

    private func transcriptionContextTerms() -> [String] {
        var terms = settings.vocabularyHints
        if !currentTitle.isEmpty {
            terms.append(currentTitle)
        }
        if let currentMeeting {
            terms.append(currentMeeting.title)
            terms.append(currentMeeting.calendarTitle)
            if let location = currentMeeting.location {
                terms.append(location)
            }
            terms.append(contentsOf: currentMeeting.participantNames)
        }

        return Array(Set(
            terms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )).sorted()
    }

    // MARK: - Background Audio Session

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            DebugLog.write("AVAudioSession activate failed: \(error)")
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func preserveDeferredCapture(at url: URL, reason: String) {
        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let recoveryDirectory = documentsURL.appendingPathComponent("TranscriptionRecovery", isDirectory: true)
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)

            let originalName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var destinationURL = recoveryDirectory.appendingPathComponent(url.lastPathComponent)
            var suffix = 1
            while FileManager.default.fileExists(atPath: destinationURL.path) {
                let uniqueName = "\(originalName)-\(suffix)"
                destinationURL = recoveryDirectory
                    .appendingPathComponent(uniqueName)
                    .appendingPathExtension(ext)
                suffix += 1
            }

            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.moveItem(at: url, to: destinationURL)
            DebugLog.write("preserved deferred capture file=\(destinationURL.lastPathComponent) reason=\(reason)")

            let preservedMessage = "Original audio preserved locally in TranscriptionRecovery."
            if let lastError, !lastError.contains(preservedMessage) {
                self.lastError = "\(lastError) \(preservedMessage)"
            } else if self.lastError == nil {
                self.lastError = preservedMessage
            }
        } catch {
            DebugLog.write("preserve deferred capture failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    // MARK: - BLE Disconnect Handling

    private func startBLEMonitoring() {
        ble.onConnectionStateChanged = { [weak self] newState in
            guard let self, self.state == .recording else { return }

            if newState == .disconnected {
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
                self.disconnectGraceTimer?.invalidate()
                self.disconnectGraceTimer = nil
                self.opusDecoder?.reset()
                // Re-enable audio stream after reconnect — completeHandshake
                // will call enableStreaming() once timeSync finishes since
                // opusFrameContinuation is still active from startOpusStream().
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
            let title = TranscriptFrontMatter.value(for: "title", in: content) ?? file.deletingPathExtension().lastPathComponent
            let dateStr = TranscriptFrontMatter.value(for: "recording_started_at", in: content)
            let date = dateStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            loaded.append(RecentTranscript(
                title: title,
                filename: file.lastPathComponent,
                date: date,
                syncStatus: .localOnly,
                fileURL: file
            ))
        }

        recentTranscripts = loaded
    }

}
