import Foundation
import Speech
import AVFoundation
import Observation

/// On-device speech recognition using SFSpeechRecognizer.
///
/// Uses chunked recognition to handle recordings of any length.
/// SFSpeechRecognizer silently degrades after ~1 minute of continuous audio,
/// so we restart the recognition task every `chunkDuration` seconds of audio
/// with overlap to avoid gaps at boundaries.
@MainActor @Observable
final class TranscriptionService {

    struct TranscriptLine: Sendable {
        let timestamp: TimeInterval
        let text: String
    }

    struct Snapshot: Sendable {
        let fullText: String
        let lines: [TranscriptLine]
    }

    var isTranscribing = false
    var fullText: String = ""
    var lastError: String?
    var isRecognizerAvailable = true
    var supportsOnDeviceRecognition = false

    /// Accumulated lines across all chunks, with absolute timestamps.
    private(set) var lines: [TranscriptLine] = []

    /// How often to restart the recognition task (seconds).
    private let chunkDuration: TimeInterval = 45

    /// Vocabulary hints for improved recognition (names, jargon, products).
    var contextualStrings: [String] = [] {
        didSet {
            preparedLanguageModelConfiguration = nil
        }
    }

    private let languageModelCache = SpeechLanguageModelCache()
    private var preparedLanguageModelConfiguration: SFSpeechLanguageModel.Configuration?

    private var recognizer: SFSpeechRecognizer?
    private var audioFormat: AVAudioFormat?

    // Current chunk state
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var chunkStartOffset: TimeInterval = 0

    // Double-buffer: next chunk's request is created before the current one ends
    private var pendingRequest: SFSpeechAudioBufferRecognitionRequest?

    // Audio timing
    private var sampleRate: Double = 16000

    // Sample batching: accumulate small Opus frames before appending to recognizer
    private var sampleBuffer: [Int16] = []
    private static let batchSize = 1600 // 100ms at 16kHz (5 Opus frames)

    // Overlap: keep last 1 second of audio to pre-fill next chunk
    private var overlapBuffer: [Int16] = []

    // Chunk line tracking
    private var committedLines: [TranscriptLine] = []
    private var currentChunkLines: [TranscriptLine] = []
    private var lastNonEmptySnapshot: Snapshot?
    private var speechResultLogCount = 0

    // Track samples fed to current chunk (for short-chunk detection)
    private var currentChunkSampleCount = 0

    // Finish flow
    private var finishContinuation: CheckedContinuation<Snapshot, Never>?
    private var finishTimeoutTask: Task<Void, Never>?

    // MARK: - Authorization

    nonisolated func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Preparation

    func prewarmLanguageModel(locale: Locale = .current) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            preparedLanguageModelConfiguration = await languageModelCache.configuration(
                for: contextualStrings,
                locale: locale
            )
        }
    }

    func refreshRecognitionSupport(locale: Locale = .current) {
        let recognizer = SFSpeechRecognizer(locale: locale)
        isRecognizerAvailable = recognizer?.isAvailable ?? false
        supportsOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: - Start / Stop

    func startTranscription(sampleRate: Double = 16000, locale: Locale = .current) {
        guard !isTranscribing else { return }
        guard configureRecognizer(locale: locale, requireOnDevice: true) else { return }

        self.sampleRate = sampleRate
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )

        resetTranscriptState()
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        startChunk()
        isTranscribing = true
    }

    func appendAudio(samples: [Int16]) {
        // Feed to whichever request is active (current or pending during transition)
        guard recognitionRequest != nil || pendingRequest != nil else { return }
        guard audioFormat != nil else { return }

        // Maintain overlap buffer (last 1 second of audio)
        overlapBuffer.append(contentsOf: samples)
        if overlapBuffer.count > overlapSampleLimit {
            overlapBuffer.removeFirst(overlapBuffer.count - overlapSampleLimit)
        }

        sampleBuffer.append(contentsOf: samples)
        if sampleBuffer.count >= Self.batchSize {
            flushSampleBuffer()
            restartChunkIfNeeded()
        }
    }

    func finishTranscription() async -> Snapshot {
        guard isTranscribing else { return snapshot() }

        flushSampleBuffer()

        let minSamplesForResult = Int(sampleRate * 2)
        let timeout: Duration = currentChunkSampleCount < minSamplesForResult ? .seconds(2) : .seconds(8)
        return await finishCurrentRecognition(timeout: timeout)
    }

    func transcribeFile(at url: URL, locale: Locale = .current) async -> Snapshot {
        teardown()
        guard configureRecognizer(locale: locale, requireOnDevice: true) else {
            return Snapshot(fullText: "", lines: [])
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        guard let recognizer else {
            return Snapshot(fullText: "", lines: [])
        }

        let customLanguageModel = await customLanguageModelConfiguration(locale: locale)
        configureRequest(request, shouldReportPartialResults: false, customLanguageModel: customLanguageModel)
        let timeout = await fileRecognitionTimeout(for: url)

        isTranscribing = true
        let signpost = PerformanceTrace.beginInterval("SpeechFileRecognition", detail: url.lastPathComponent)

        var didResume = false
        var timeoutTask: Task<Void, Never>?
        let finalSnapshot: Snapshot = await withCheckedContinuation { (continuation: CheckedContinuation<Snapshot, Never>) in
            func resumeOnce(_ snapshot: Snapshot) {
                guard !didResume else { return }
                didResume = true
                timeoutTask?.cancel()
                continuation.resume(returning: snapshot)
            }

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !didResume else { return }
                self.lastError = "Speech recognition timed out for prerecorded audio"
                self.recognitionTask?.cancel()
                resumeOnce(self.snapshotWithFallback())
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, !didResume else { return }

                    if let result {
                        let resultSnapshot = self.snapshot(from: result, chunkOffset: 0)
                        if result.isFinal {
                            self.lastError = nil
                            resumeOnce(resultSnapshot)
                        }
                        return
                    }

                    if let error {
                        self.lastError = error.localizedDescription
                        resumeOnce(self.snapshotWithFallback())
                    }
                }
            }
        }

        timeoutTask?.cancel()

        PerformanceTrace.endInterval("SpeechFileRecognition", state: signpost, detail: "chars=\(finalSnapshot.fullText.count)")
        DebugLog.write("file transcription fullTextLen=\(finalSnapshot.fullText.count) lines=\(finalSnapshot.lines.count)")
        teardown()
        return finalSnapshot
    }

    // MARK: - Chunked Recognition

    private func startChunk() {
        guard let recognizer else { return }

        let request = pendingRequest ?? makeRequest()
        pendingRequest = nil
        recognitionRequest = request
        currentChunkSampleCount = 0

        let offset = chunkStartOffset
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleChunkResult(result, error: error, chunkOffset: offset)
            }
        }
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        configureRequest(request, shouldReportPartialResults: true, customLanguageModel: preparedLanguageModelConfiguration)
        return request
    }

    private func configureRequest(
        _ request: SFSpeechRecognitionRequest,
        shouldReportPartialResults: Bool,
        customLanguageModel: SFSpeechLanguageModel.Configuration?
    ) {
        request.shouldReportPartialResults = shouldReportPartialResults
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(iOS 17, *) {
            request.addsPunctuation = true
            request.customizedLanguageModel = customLanguageModel
        }
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
    }

    /// Finalize current chunk and start a new one with seamless transition.
    private func restartChunk() {
        guard isTranscribing, finishContinuation == nil else { return }

        committedLines = sanitizeTranscriptLines(mergedTranscriptLines(committedLines, with: currentChunkLines))
        currentChunkLines = []

        // Update offset for the next chunk based on audio duration, not wall time.
        chunkStartOffset += Double(currentChunkSampleCount) / sampleRate

        // Create next request BEFORE ending current one (double-buffer)
        let nextRequest = makeRequest()
        pendingRequest = nextRequest

        // Pre-fill the next request with overlap audio (last ~1 second)
        if !overlapBuffer.isEmpty {
            feedSamples(overlapBuffer, to: nextRequest)
        }

        // Flush remaining audio to current request, then end it
        flushSampleBuffer()
        recognitionRequest?.endAudio()

        let oldTask = recognitionTask

        // Start new chunk immediately — no gap
        recognitionRequest = nil
        oldTask?.cancel()
        startChunk()
    }

    // MARK: - Results

    private func handleChunkResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        chunkOffset: TimeInterval
    ) {
        if let result {
            let snapshot = snapshot(from: result, chunkOffset: chunkOffset)

            speechResultLogCount += 1
            if speechResultLogCount <= 3 || result.isFinal {
                DebugLog.write(
                    "speech result #\(speechResultLogCount) final=\(result.isFinal) segments=\(result.bestTranscription.segments.count) lines=\(snapshot.lines.count) formattedLen=\(snapshot.fullText.count)"
                )
            }

            let hasExistingTranscript = !(committedLines.isEmpty && currentChunkLines.isEmpty)
            if snapshot.lines.isEmpty, hasExistingTranscript {
                if result.isFinal, finishContinuation != nil {
                    completeIfNeeded()
                }
                return
            }

            currentChunkLines = snapshot.lines
            updateMergedTranscript(formattedFallback: snapshot.fullText)

            if result.isFinal, finishContinuation != nil {
                completeIfNeeded()
            }
            return
        }

        if error != nil, finishContinuation != nil {
            completeIfNeeded()
        }
    }

    private func snapshot(from result: SFSpeechRecognitionResult, chunkOffset: TimeInterval) -> Snapshot {
        let formattedText = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segmentLines = result.bestTranscription.segments.compactMap { segment -> TranscriptLine? in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(
                timestamp: chunkOffset + segment.timestamp,
                text: text
            )
        }
        let lines: [TranscriptLine]
        if !segmentLines.isEmpty {
            lines = segmentLines
        } else if !formattedText.isEmpty {
            lines = [TranscriptLine(timestamp: chunkOffset, text: formattedText)]
        } else {
            lines = []
        }

        let sanitizedLines = sanitizeTranscriptLines(lines)
        let combinedText = sanitizedLines.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let snapshot = Snapshot(
            fullText: combinedText.isEmpty ? formattedText : combinedText,
            lines: sanitizedLines
        )

        if !snapshot.fullText.isEmpty || !snapshot.lines.isEmpty {
            lastNonEmptySnapshot = snapshot
        }

        return snapshot
    }

    // MARK: - Buffer Management

    private func flushSampleBuffer() {
        guard !sampleBuffer.isEmpty else { return }

        let samples = sampleBuffer
        sampleBuffer = []

        // Feed to the active request (current or pending)
        if let request = recognitionRequest {
            feedSamples(samples, to: request)
            currentChunkSampleCount += samples.count
        } else if let request = pendingRequest {
            feedSamples(samples, to: request)
        }
    }

    private func feedSamples(_ samples: [Int16], to request: SFSpeechAudioBufferRecognitionRequest) {
        guard let format = audioFormat else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        if let channelData = buffer.int16ChannelData {
            samples.withUnsafeBufferPointer { src in
                guard let baseAddress = src.baseAddress else { return }
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }

        request.append(buffer)
    }

    // MARK: - Finish Flow

    private func forceCompleteIfNeeded() {
        guard finishContinuation != nil else { return }
        completeIfNeeded()
    }

    private func restartChunkIfNeeded() {
        guard currentChunkSampleCount >= chunkSampleLimit else { return }
        restartChunk()
    }

    private func completeIfNeeded() {
        lines = sanitizeTranscriptLines(mergedTranscriptLines(committedLines, with: currentChunkLines))
        fullText = lines.map(\.text).joined(separator: " ")
        rememberNonEmptySnapshotIfNeeded()

        let result = snapshotWithFallback()
        DebugLog.write("finish transcription fullTextLen=\(result.fullText.count) lines=\(result.lines.count)")
        let continuation = finishContinuation
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        teardown()
        continuation?.resume(returning: result)
    }

    private func finishCurrentRecognition(timeout: Duration) async -> Snapshot {
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
            finishTimeoutTask?.cancel()
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.forceCompleteIfNeeded()
            }
            recognitionRequest?.endAudio()
        }
    }

    private func teardown() {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishContinuation = nil
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        pendingRequest = nil
        recognizer = nil
        audioFormat = nil
        isTranscribing = false
        resetTranscriptState()
        isRecognizerAvailable = true
    }

    private var chunkSampleLimit: Int {
        Int(sampleRate * chunkDuration)
    }

    private var overlapSampleLimit: Int {
        Int(sampleRate)
    }

    private func updateMergedTranscript(formattedFallback: String? = nil) {
        lines = sanitizeTranscriptLines(mergedTranscriptLines(committedLines, with: currentChunkLines))
        let mergedText = lines.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !mergedText.isEmpty {
            fullText = mergedText
        } else if let formattedFallback, !formattedFallback.isEmpty {
            fullText = formattedFallback
        } else {
            fullText = ""
        }
        rememberNonEmptySnapshotIfNeeded()
    }

    private func resetTranscriptState() {
        lines = []
        committedLines = []
        currentChunkLines = []
        fullText = ""
        sampleBuffer = []
        overlapBuffer = []
        chunkStartOffset = 0
        currentChunkSampleCount = 0
        lastNonEmptySnapshot = nil
        speechResultLogCount = 0
    }

    private func sanitizeTranscriptLines(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(timestamp: line.timestamp, text: text)
        }
    }

    private func rememberNonEmptySnapshotIfNeeded() {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !lines.isEmpty else { return }
        lastNonEmptySnapshot = Snapshot(fullText: fullText, lines: lines)
    }

    private func snapshotWithFallback() -> Snapshot {
        let current = snapshot()
        let trimmed = current.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, current.lines.isEmpty, let fallback = lastNonEmptySnapshot {
            return fallback
        }
        return current
    }

    private func snapshot() -> Snapshot {
        Snapshot(fullText: fullText, lines: lines)
    }

    private func configureRecognizer(locale: Locale, requireOnDevice: Bool) -> Bool {
        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer else {
            lastError = "Speech recognition unavailable for \(locale.identifier)"
            return false
        }

        isRecognizerAvailable = recognizer.isAvailable
        supportsOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        guard recognizer.isAvailable else {
            lastError = "Speech recognition unavailable for \(locale.identifier)"
            return false
        }

        if requireOnDevice, !recognizer.supportsOnDeviceRecognition {
            lastError = "On-device speech recognition unavailable for \(locale.identifier)"
            return false
        }

        lastError = nil
        return true
    }

    private func customLanguageModelConfiguration(locale: Locale) async -> SFSpeechLanguageModel.Configuration? {
        guard #available(iOS 17, *) else { return nil }
        if let preparedLanguageModelConfiguration {
            return preparedLanguageModelConfiguration
        }
        let configuration = await languageModelCache.configuration(for: contextualStrings, locale: locale)
        preparedLanguageModelConfiguration = configuration
        return configuration
    }

    private func fileRecognitionTimeout(for url: URL) async -> Duration {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        let seconds = duration.map(CMTimeGetSeconds) ?? 0
        guard seconds.isFinite, seconds > 0 else {
            return .seconds(300)
        }

        let timeoutSeconds = min(max(seconds * 2, 60), 600)
        return .seconds(Int64(timeoutSeconds.rounded(.up)))
    }

    private func mergedTranscriptLines(_ existing: [TranscriptLine], with incoming: [TranscriptLine]) -> [TranscriptLine] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        let maxOverlap = min(5, existing.count, incoming.count)
        for overlap in stride(from: maxOverlap, through: 2, by: -1) {
            let existingSuffix = existing.suffix(overlap).map { normalizedBoundaryText($0.text) }
            let incomingPrefix = incoming.prefix(overlap).map { normalizedBoundaryText($0.text) }
            if existingSuffix == incomingPrefix {
                return existing + incoming.dropFirst(overlap)
            }
        }

        return existing + incoming
    }

    private func normalizedBoundaryText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
