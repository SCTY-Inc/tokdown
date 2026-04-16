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

        return try await withThrowingTaskGroup(of: (String, [TranscriptLine]).self) { group in
            group.addTask {
                let transcriber = SpeechTranscriber(
                    locale: .current,
                    preset: .timeIndexedProgressiveTranscription
                )
                let audioFile = try AVAudioFile(forReading: audioURL)
                // Keep analyzer alive — it drives the transcription pipeline
                let _analyzer = try await SpeechAnalyzer(
                    inputAudioFile: audioFile,
                    modules: [transcriber],
                    finishAfterFile: true
                )
                _ = _analyzer

                var lines: [TranscriptLine] = []
                for try await result in transcriber.results where result.isFinal {
                    let seconds = CMTimeGetSeconds(result.range.start)
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        lines.append(TranscriptLine(timestamp: seconds, text: text))
                    }
                }
                return (lines.map(\.text).joined(separator: " "), lines)
            }

            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw TranscriptionError.timeout
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TranscriptionError.timeout
            }
            return result
        }
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
