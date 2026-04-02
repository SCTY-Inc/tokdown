import Foundation
import Speech
import AVFoundation

/// On-device speech recognition using SFSpeechRecognizer.
///
/// Uses chunked recognition to handle recordings of any length.
/// SFSpeechRecognizer silently degrades after ~1 minute of continuous audio,
/// so we restart the recognition task every `chunkDuration` seconds and
/// stitch results with time offsets.
@MainActor
final class TranscriptionService: ObservableObject {

    struct TranscriptLine: Sendable {
        let timestamp: TimeInterval
        let text: String
    }

    struct Snapshot: Sendable {
        let fullText: String
        let lines: [TranscriptLine]
    }

    @Published var isTranscribing = false
    @Published var fullText: String = ""

    /// Accumulated lines across all chunks, with absolute timestamps.
    private(set) var lines: [TranscriptLine] = []

    /// How often to restart the recognition task (seconds).
    private let chunkDuration: TimeInterval = 30

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFormat: AVAudioFormat?

    /// Seconds elapsed since recording started (drives chunk restarts).
    private var recordingStartTime: Date?
    private var chunkStartOffset: TimeInterval = 0
    private var chunkTimer: Timer?

    /// Segments already captured from the current chunk's partial results.
    private var currentChunkSegmentCount = 0

    /// Buffer for batching small Opus frames into larger PCM buffers.
    private var sampleBuffer: [Int16] = []
    private static let batchSize = 1600 // 100ms at 16kHz (5 Opus frames)

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
        guard let recognizer, recognizer.isAvailable else { return }

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
        recordingStartTime = Date()
        chunkStartOffset = 0
        currentChunkSegmentCount = 0
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        startChunk()

        // Restart recognition every chunkDuration seconds
        chunkTimer = Timer.scheduledTimer(
            withTimeInterval: chunkDuration,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartChunk()
            }
        }

        isTranscribing = true
    }

    func appendAudio(samples: [Int16]) {
        guard recognitionRequest != nil, audioFormat != nil else { return }

        // Batch small frames into larger buffers to reduce overhead
        sampleBuffer.append(contentsOf: samples)
        if sampleBuffer.count >= Self.batchSize {
            flushSampleBuffer()
        }
    }

    func finishTranscription() async -> Snapshot {
        guard isTranscribing else { return snapshot() }

        chunkTimer?.invalidate()
        chunkTimer = nil

        // Flush any remaining audio
        flushSampleBuffer()

        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
            finishTimeoutTask?.cancel()
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.forceCompleteIfNeeded()
            }
            recognitionRequest?.endAudio()
        }
    }

    // MARK: - Chunked Recognition

    private func startChunk() {
        guard let recognizer, let audioFormat else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 17, *) {
            request.addsPunctuation = true
        }

        recognitionRequest = request
        currentChunkSegmentCount = 0

        let offset = chunkStartOffset
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleChunkResult(result, error: error, chunkOffset: offset)
            }
        }
    }

    /// Finalize current chunk and start a new one.
    private func restartChunk() {
        guard isTranscribing, finishContinuation == nil else { return }

        // Flush pending audio and end current request
        flushSampleBuffer()
        recognitionRequest?.endAudio()

        // Commit current chunk's lines so they're preserved
        committedLines = lines

        let oldTask = recognitionTask
        let oldRequest = recognitionRequest

        // Update offset for the next chunk
        if let start = recordingStartTime {
            chunkStartOffset = Date().timeIntervalSince(start)
        }

        // Brief pause for recognizer to finalize, then start new chunk
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isTranscribing else { return }
            oldTask?.cancel()
            _ = oldRequest
            self.currentChunkLines = []
            self.startChunk()
        }
    }

    // MARK: - Results

    /// Lines committed from previous chunks (immutable once chunk ends).
    private var committedLines: [TranscriptLine] = []
    /// Lines from the current in-progress chunk (replaced on each partial result).
    private var currentChunkLines: [TranscriptLine] = []

    private func handleChunkResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        chunkOffset: TimeInterval
    ) {
        if let result {
            // Replace current chunk lines with latest partial/final result
            currentChunkLines = result.bestTranscription.segments.map { segment in
                TranscriptLine(
                    timestamp: chunkOffset + segment.timestamp,
                    text: segment.substring
                )
            }

            // Merge committed + current for display
            lines = committedLines + currentChunkLines
            fullText = lines.map(\.text).joined(separator: " ")

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
        guard !sampleBuffer.isEmpty, let request = recognitionRequest, let format = audioFormat else {
            return
        }

        let samples = sampleBuffer
        sampleBuffer = []

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

    private func completeIfNeeded() {
        let result = snapshot()
        let continuation = finishContinuation
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        chunkTimer?.invalidate()
        chunkTimer = nil

        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        audioFormat = nil
        isTranscribing = false
        sampleBuffer = []

        continuation?.resume(returning: result)
    }

    private func snapshot() -> Snapshot {
        Snapshot(fullText: fullText, lines: lines)
    }
}
