import Foundation
import AppKit
import Synchronization
import ScreenCaptureKit
import AVFoundation

private enum SystemAudioCaptureFormat {
    static let sampleRate = 48_000
    static let channelCount = 2
    static let bitRate = 128_000
}

@MainActor
final class SystemAudioService: NSObject {
    private var stream: SCStream?
    private var outputHandler: AudioOutputHandler?
    private var screenOutputHandler: ScreenOutputHandler?
    private var outputURL: URL?

    private(set) var isRecording = false

    func startCapture(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = preferredDisplay(from: content.displays) else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = SystemAudioCaptureFormat.sampleRate
        config.channelCount = SystemAudioCaptureFormat.channelCount
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SystemAudioCaptureFormat.sampleRate,
            AVNumberOfChannelsKey: SystemAudioCaptureFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: SystemAudioCaptureFormat.bitRate
        ])
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SystemAudioError.writeFailed(writer.error)
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw SystemAudioError.writeFailed(writer.error)
        }

        let handler = AudioOutputHandler(writer: writer, input: input)
        let screenHandler = ScreenOutputHandler()
        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)

        outputHandler = handler
        screenOutputHandler = screenHandler
        outputURL = url
        isRecording = false

        do {
            try scStream.addStreamOutput(screenHandler, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.capture"))
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
        screenOutputHandler = nil

        if let handler {
            do {
                try await handler.finish()
            } catch {
                if let url {
                    Self.removePartialCaptureFile(at: url)
                }
                throw error
            }
        }

        return url
    }

    private func rollbackFailedStart(stream: SCStream, handler: AudioOutputHandler, outputURL: URL) async {
        try? await stream.stopCapture()
        await handler.cancel()

        Self.removePartialCaptureFile(at: outputURL)

        self.stream = nil
        self.outputHandler = nil
        self.screenOutputHandler = nil
        self.outputURL = nil
        self.isRecording = false
    }

    private func preferredDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

        let mouseLocation = NSEvent.mouseLocation
        if let hoveredDisplayID = displayID(for: NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })),
           let hoveredDisplay = displays.first(where: { $0.displayID == hoveredDisplayID }) {
            return hoveredDisplay
        }

        if let mainDisplayID = displayID(for: NSScreen.main),
           let mainDisplay = displays.first(where: { $0.displayID == mainDisplayID }) {
            return mainDisplay
        }

        return displays.first
    }

    private func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }

    nonisolated static func removePartialCaptureFile(at url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}

private final class ScreenOutputHandler: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
    }
}

private final class AudioOutputHandler: NSObject, SCStreamOutput {
    // Invariant: all writer access wrapped by `queue` — see capture callback and `finish()`.
    // Rationale: ScreenCaptureKit capture runs on its own queue; writer mutations must be serialized.
    nonisolated(unsafe) private let writer: AVAssetWriter
    nonisolated(unsafe) private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "audio.writer")
    private let sessionStarted = Mutex(false)
    private let appendedAudioSample = Mutex(false)

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

            guard input.isReadyForMoreMediaData else { return }
            if input.append(sampleBuffer) {
                appendedAudioSample.withLock { $0 = true }
            }
        }
    }

    @MainActor func finish() async throws {
        // Drain the writer queue to ensure no in-flight appends
        queue.sync {}

        let appendedAudio = appendedAudioSample.withLock { $0 }
        guard appendedAudio else {
            await cancel()
            throw SystemAudioError.noAudioCaptured
        }

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
    case noAudioCaptured
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display found for audio capture."
        case .noAudioCaptured:
            return "No system audio was captured."
        case .writeFailed(let underlying):
            if let msg = underlying?.localizedDescription {
                return "Audio write failed: \(msg)"
            }
            return "Audio write failed."
        }
    }
}
