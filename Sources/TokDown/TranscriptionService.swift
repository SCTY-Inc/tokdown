import Foundation
import Speech
import AVFoundation
import Observation

/// On-device speech recognition using SFSpeechRecognizer.
///
/// Uses chunked recognition to handle recordings of any length.
/// SFSpeechRecognizer silently degrades after ~1 minute of continuous audio,
/// so we restart the recognition task every `chunkDuration` seconds with
/// audio overlap to avoid gaps at boundaries.
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

    /// Accumulated lines across all chunks, with absolute timestamps.
    private(set) var lines: [TranscriptLine] = []

    /// How often to restart the recognition task (seconds).
    private let chunkDuration: TimeInterval = 45

    /// Vocabulary hints for improved recognition (names, jargon, products).
    var contextualStrings: [String] = []

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

    // MARK: - Start / Stop

    func startTranscription(sampleRate: Double = 16000) {
        guard !isTranscribing else { return }

        recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition unavailable for \(Locale.current.identifier)"
            return
        }
        lastError = nil

        self.sampleRate = sampleRate
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )

        lines = []
        committedLines = []
        currentChunkLines = []
        fullText = ""
        sampleBuffer = []
        overlapBuffer = []
        currentChunkSampleCount = 0
        chunkStartOffset = 0
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        lastNonEmptySnapshot = nil
        speechResultLogCount = 0

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

        // If current chunk has very little audio (<2s), don't wait for it
        let minSamplesForResult = Int(sampleRate * 2)
        if currentChunkSampleCount < minSamplesForResult {
            // Commit what we have and return immediately.
            // Preserve the last non-empty live transcript if Speech emits an
            // empty closing update while the user stops recording.
            lines = sanitizeTranscriptLines(committedLines + currentChunkLines)
            fullText = lines.map(\.text).joined(separator: " ")
            rememberNonEmptySnapshotIfNeeded()
            let result = snapshotWithFallback()
            DebugLog.write("finish short chunk fullTextLen=\(result.fullText.count) lines=\(result.lines.count) samples=\(currentChunkSampleCount)")
            teardown()
            return result
        }

        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
            finishTimeoutTask?.cancel()
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.forceCompleteIfNeeded()
            }
            recognitionRequest?.endAudio()
        }
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
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 17, *) {
            request.addsPunctuation = true
        }
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        return request
    }

    /// Finalize current chunk and start a new one with seamless transition.
    private func restartChunk() {
        guard isTranscribing, finishContinuation == nil else { return }

        // Commit current chunk's lines
        committedLines = sanitizeTranscriptLines(committedLines + currentChunkLines)
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
            let resolvedChunkLines: [TranscriptLine]
            if !segmentLines.isEmpty {
                resolvedChunkLines = segmentLines
            } else if !formattedText.isEmpty {
                resolvedChunkLines = [TranscriptLine(timestamp: chunkOffset, text: formattedText)]
            } else {
                resolvedChunkLines = []
            }

            speechResultLogCount += 1
            if speechResultLogCount <= 3 || result.isFinal {
                DebugLog.write(
                    "speech result #\(speechResultLogCount) final=\(result.isFinal) segments=\(result.bestTranscription.segments.count) nonEmpty=\(resolvedChunkLines.count) formattedLen=\(formattedText.count)"
                )
            }

            let hasExistingTranscript = !(committedLines.isEmpty && currentChunkLines.isEmpty)
            if resolvedChunkLines.isEmpty, hasExistingTranscript {
                if result.isFinal, finishContinuation != nil {
                    completeIfNeeded()
                }
                return
            }

            currentChunkLines = resolvedChunkLines
            updateMergedTranscript(formattedFallback: formattedText)

            if result.isFinal, finishContinuation != nil {
                completeIfNeeded()
            }
            return
        }

        if error != nil, finishContinuation != nil {
            completeIfNeeded()
        }
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
        lines = sanitizeTranscriptLines(committedLines + currentChunkLines)
        deduplicateChunkBoundaries()
        lines = sanitizeTranscriptLines(lines)
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

    private func teardown() {
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        pendingRequest = nil
        recognizer = nil
        audioFormat = nil
        isTranscribing = false
        sampleBuffer = []
        overlapBuffer = []
    }

    private var chunkSampleLimit: Int {
        Int(sampleRate * chunkDuration)
    }

    private var overlapSampleLimit: Int {
        Int(sampleRate)
    }

    private func updateMergedTranscript(formattedFallback: String? = nil) {
        lines = sanitizeTranscriptLines(committedLines + currentChunkLines)
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

    // MARK: - Chunk Boundary Deduplication

    /// Remove duplicate words at chunk boundaries caused by audio overlap.
    /// Compares last N words of one chunk with first N words of the next.
    private func deduplicateChunkBoundaries() {
        guard lines.count > 1 else { return }

        var result: [TranscriptLine] = [lines[0]]
        let words = 5 // compare window

        for i in 1..<lines.count {
            let prev = result.last?.text.lowercased().split(separator: " ").suffix(words) ?? []
            let curr = lines[i].text.lowercased().split(separator: " ")

            // Check if current line starts with words that match the end of previous line
            if !prev.isEmpty, !curr.isEmpty {
                var overlapLen = 0
                for len in (1...min(prev.count, curr.count)).reversed() {
                    if Array(prev.suffix(len)) == Array(curr.prefix(len)) {
                        overlapLen = len
                        break
                    }
                }

                if overlapLen > 0 {
                    // Trim the overlapping prefix from current line
                    let trimmedWords = lines[i].text.split(separator: " ").dropFirst(overlapLen)
                    if trimmedWords.isEmpty { continue } // entire line was duplicate
                    result.append(TranscriptLine(
                        timestamp: lines[i].timestamp,
                        text: trimmedWords.joined(separator: " ")
                    ))
                    continue
                }
            }

            result.append(lines[i])
        }

        lines = result
    }
}
