import Foundation
import Speech

@MainActor
final class TranscriptionService {
    func requestPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    func transcribe(audioURL: URL) async throws -> (String, [TranscriptLine]) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.authorizationNeeded
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }

                let lines = result.bestTranscription.segments.map {
                    TranscriptLine(
                        timestamp: $0.timestamp,
                        text: $0.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }

                if !resumed {
                    resumed = true
                    continuation.resume(returning: (result.bestTranscription.formattedString, lines))
                }
            }
        }
    }
}

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case authorizationNeeded

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: "Speech recognizer unavailable."
        case .authorizationNeeded: "Speech recognition permission not granted."
        }
    }
}
