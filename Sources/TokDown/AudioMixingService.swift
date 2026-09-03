import AVFoundation
import Foundation

/// Combines system output and microphone capture into one local audio file for transcription.
struct AudioMixingService {
    func mix(systemAudioURL: URL, microphoneURL: URL, outputURL: URL) async throws -> URL {
        let composition = AVMutableComposition()
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        for sourceURL in [systemAudioURL, microphoneURL] {
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudioMixingError.missingAudioTrack(sourceURL)
            }

            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                throw AudioMixingError.invalidAudio(sourceURL)
            }

            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )

            // Summing two full-scale sources at half gain prevents clipping.
            let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
            parameters.setVolume(0.5, at: .zero)
            inputParameters.append(parameters)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioMixingError.couldNotCreateExporter
        }

        exporter.audioMix = audioMix
        do {
            try await exporter.export(to: outputURL, as: .m4a)
        } catch {
            throw AudioMixingError.exportFailed(error)
        }

        return outputURL
    }
}

enum AudioMixingError: LocalizedError {
    case missingAudioTrack(URL)
    case invalidAudio(URL)
    case couldNotCreateExporter
    case exportFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack(let url):
            return "No audio track found in \(url.lastPathComponent)."
        case .invalidAudio(let url):
            return "Invalid audio in \(url.lastPathComponent)."
        case .couldNotCreateExporter:
            return "Could not prepare the meeting audio mix."
        case .exportFailed(let error):
            return "Could not combine meeting audio: \(error.localizedDescription)"
        }
    }
}
