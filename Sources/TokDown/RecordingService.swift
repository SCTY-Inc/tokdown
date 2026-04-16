import Foundation
import AVFoundation

@MainActor
final class RecordingService {
    private var recorder: AVAudioRecorder?

    nonisolated static func microphoneAccessGranted(for status: AVAuthorizationStatus) -> Bool? {
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return nil
        @unknown default: return false
        }
    }

    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if let resolved = Self.microphoneAccessGranted(for: status) { return resolved }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startRecording(to url: URL) throws {
        _ = stopRecording()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.prepareToRecord()
        guard recorder?.record() == true else {
            throw NSError(domain: "RecordingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start recorder"])
        }
    }

    func stopRecording() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        let url = recorder.url
        self.recorder = nil
        return url
    }
}
