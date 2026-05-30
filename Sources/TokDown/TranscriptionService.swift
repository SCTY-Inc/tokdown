import Foundation
import Speech
import AVFoundation
import CoreMedia

enum SpeechRecognitionAccessState: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined

    init(status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .restricted
        }
    }

    var failureMessage: String? {
        switch self {
        case .authorized:
            return nil
        case .denied:
            return "Speech recognition permission denied. Enable it in System Settings to transcribe recordings."
        case .restricted:
            return "Speech recognition is restricted on this Mac."
        case .notDetermined:
            return "Speech recognition permission is required before recording can start."
        }
    }
}

@MainActor
final class TranscriptionService {
    func speechRecognitionAccessState(requestingIfNeeded: Bool = false) async -> SpeechRecognitionAccessState {
        let currentState = SpeechRecognitionAccessState(status: SFSpeechRecognizer.authorizationStatus())
        guard requestingIfNeeded, currentState == .notDetermined else {
            return currentState
        }

        let requestedStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return SpeechRecognitionAccessState(status: requestedStatus)
    }

    func ensureModelAvailable() async throws {
        let transcriber = SpeechTranscriber(locale: .current, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            try await request.downloadAndInstall()
        case .unsupported:
            throw TranscriptionError.modelNotInstalled
        @unknown default:
            return
        }
    }

    func modelNeedsDownload() async -> Bool {
        let transcriber = SpeechTranscriber(locale: .current, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed: return false
        default: return true
        }
    }

    func transcribe(audioURL: URL) async throws -> (fullText: String, lines: [TranscriptLine]) {
        try await ensureModelAvailable()

        // Scale the watchdog to the recording length. A fixed 5-min cap silently
        // failed long recordings ("(Transcription failed)" on good audio); on-device
        // transcription runs faster than real time, so duration + generous slack is
        // a safe upper bound that still catches a genuinely hung analyzer.
        let timeoutSeconds = Self.transcriptionTimeoutSeconds(forAudioAt: audioURL)

        return try await withThrowingTaskGroup(of: (String, [TranscriptLine]).self) { group in
            group.addTask {
                let transcriber = SpeechTranscriber(
                    locale: .current,
                    preset: .timeIndexedProgressiveTranscription
                )
                let audioFile = try AVAudioFile(forReading: audioURL)
                let analyzer = try await SpeechAnalyzer(
                    inputAudioFile: audioFile,
                    modules: [transcriber],
                    finishAfterFile: true
                )

                var lines: [TranscriptLine] = []
                for try await result in transcriber.results where result.isFinal {
                    let seconds = CMTimeGetSeconds(result.range.start)
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        lines.append(TranscriptLine(timestamp: seconds, text: text))
                    }
                }
                _ = analyzer  // must follow the async loop — prevents ARC from dropping before pipeline drains
                return (lines.map(\.text).joined(separator: " "), lines)
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw TranscriptionError.timeout
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TranscriptionError.timeout
            }
            return result
        }
    }

    /// Watchdog budget: at least 5 min, otherwise ~2x the audio duration plus a
    /// 60s floor for model warm-up. Falls back to a long default if duration is
    /// unreadable rather than risking a premature timeout.
    nonisolated static func transcriptionTimeoutSeconds(forAudioAt url: URL) -> Int {
        guard let duration = audioDurationSeconds(at: url), duration > 0 else {
            return unknownDurationTimeoutSeconds
        }
        return transcriptionTimeoutSeconds(forDurationSeconds: duration)
    }

    /// Long default when duration is unreadable — never risk a premature timeout on
    /// a recording we simply couldn't measure.
    nonisolated static let unknownDurationTimeoutSeconds = 1_800

    nonisolated static func transcriptionTimeoutSeconds(forDurationSeconds duration: Double) -> Int {
        guard duration > 0 else { return unknownDurationTimeoutSeconds }
        return max(300, Int(duration * 2) + 60)
    }

    private nonisolated static func audioDurationSeconds(at url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotInstalled
    case timeout

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "Speech model not available for this locale."
        case .timeout:
            return "Transcription timed out. The speech model may be unavailable or the recording too long."
        }
    }
}
