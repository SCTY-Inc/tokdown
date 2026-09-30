import Foundation
import AVFoundation

/// Renders PCM samples to a local audio file for deferred transcription.
///
/// The file uses 16-bit mono linear PCM at 16 kHz, which is easy to generate
/// from the decoded Opus frames and works well with Apple's file-based Speech API.
final class PCMRenderFile {

    let url: URL

    private let format: AVAudioFormat
    private let file: AVAudioFile

    init(sampleRate: Double = 16000, baseDirectory: URL? = nil) throws {
        let directory = (baseDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("TokDownPCM", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        self.format = format
        self.file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func append(samples: [Int16]) throws {
        guard !samples.isEmpty else { return }
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.int16ChannelData {
            samples.withUnsafeBufferPointer { source in
                guard let baseAddress = source.baseAddress else { return }
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
