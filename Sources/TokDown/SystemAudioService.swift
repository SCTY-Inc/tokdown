import Foundation
import Synchronization
import ScreenCaptureKit
import AVFoundation

@MainActor
final class SystemAudioService: NSObject {
    private var stream: SCStream?
    private var outputHandler: AudioOutputHandler?
    private var outputURL: URL?

    private(set) var isRecording = false

    func startCapture(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 44_100
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()

        let handler = AudioOutputHandler(writer: writer, input: input)
        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)

        outputHandler = handler
        outputURL = url
        isRecording = false

        do {
            try scStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.capture"))
            try await scStream.startCapture()
        } catch {
            await rollbackFailedStart(stream: scStream, handler: handler, outputURL: url)
            throw error
        }

        stream = scStream
        isRecording = true
    }

    func stopCapture() async throws -> URL? {
        guard let stream else { return nil }
        try? await stream.stopCapture()

        self.stream = nil
        isRecording = false

        let url = outputURL
        let handler = outputHandler
        outputURL = nil
        outputHandler = nil

        if let handler { try await handler.finish() }

        return url
    }

    private func rollbackFailedStart(stream: SCStream, handler: AudioOutputHandler, outputURL: URL) async {
        try? await stream.stopCapture()
        await handler.cancel()

        Self.removePartialCaptureFile(at: outputURL)

        self.stream = nil
        self.outputHandler = nil
        self.outputURL = nil
        self.isRecording = false
    }

    nonisolated static func removePartialCaptureFile(at url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}

private final class AudioOutputHandler: NSObject, SCStreamOutput {
    // Invariant: all writer access wrapped by `queue` — see capture callback and `finish()`.
    // Rationale: ScreenCaptureKit capture runs on its own queue; writer mutations must be serialized.
    nonisolated(unsafe) private let writer: AVAssetWriter
    nonisolated(unsafe) private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "audio.writer")
    private let sessionStarted = Mutex(false)

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        queue.sync {
            sessionStarted.withLock { started in
                if !started {
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    started = true
                }
            }

            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    @MainActor func finish() async throws {
        // Drain the writer queue to ensure no in-flight appends
        queue.sync {}
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw SystemAudioError.writeFailed(writer.error)
        }
    }

    @MainActor func cancel() async {
        queue.sync {}
        input.markAsFinished()
        writer.cancelWriting()
    }
}

enum SystemAudioError: LocalizedError {
    case noDisplay
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display found for audio capture."
        case .writeFailed(let underlying):
            if let msg = underlying?.localizedDescription {
                return "Audio write failed: \(msg)"
            }
            return "Audio write failed."
        }
    }
}
