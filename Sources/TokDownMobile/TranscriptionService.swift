import Foundation
import Speech
import AVFoundation

/// On-device speech recognition using SFSpeechRecognizer.
/// Uses on-device recognition for privacy. Streams results as TranscriptLine entries.
///
/// Future: migrate to SpeechTranscriber when targeting iOS 26+.
@MainActor
final class TranscriptionService: ObservableObject {

    struct TranscriptLine: Sendable {
        let timestamp: TimeInterval
        let text: String
    }

    @Published var isTranscribing = false
    @Published var lines: [TranscriptLine] = []
    @Published var fullText: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFormat: AVAudioFormat?
    private var recordingStartTime: Date?
    private var lastSegmentCount = 0

    /// Request speech recognition authorization.
    /// - Returns: true if authorized
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Start transcribing from a PCM audio buffer stream.
    /// - Parameter sampleRate: Audio sample rate (16000 for pendant)
    func startTranscription(sampleRate: Double = 16000) {
        guard !isTranscribing else { return }

        recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 17, *) {
            request.addsPunctuation = true
        }

        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )

        lines = []
        fullText = ""
        lastSegmentCount = 0
        recordingStartTime = Date()
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleResult(result, error: error)
            }
        }

        isTranscribing = true
    }

    /// Append PCM samples to the active recognition request.
    /// - Parameter samples: Int16 PCM samples at configured sample rate
    func appendAudio(samples: [Int16]) {
        guard let request = recognitionRequest, let format = audioFormat else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        if let channelData = buffer.int16ChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        request.append(buffer)
    }

    /// Stop transcription and finalize results.
    func stopTranscription() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
        audioFormat = nil
        isTranscribing = false
    }

    // MARK: - Private

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard let result else {
            if error != nil {
                stopTranscription()
            }
            return
        }

        fullText = result.bestTranscription.formattedString

        let segments = result.bestTranscription.segments
        if segments.count > lastSegmentCount {
            for segment in segments[lastSegmentCount...] {
                let line = TranscriptLine(
                    timestamp: segment.timestamp,
                    text: segment.substring
                )
                lines.append(line)
            }
            lastSegmentCount = segments.count
        }

        if result.isFinal {
            fullText = result.bestTranscription.formattedString
        }
    }
}
