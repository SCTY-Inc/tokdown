import Foundation
import Speech
import AVFoundation
import CoreMedia

@MainActor
final class TranscriptionService {
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

    func transcribe(audioURL: URL) async throws -> (fullText: String, lines: [TranscriptLine]) {
        try await ensureModelAvailable()

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

        let fullText = lines.map(\.text).joined(separator: " ")
        return (fullText, lines)
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: "Speech model not available for this locale."
        }
    }
}
