import AVFoundation
import Foundation
import Testing
@testable import TokDown

struct AudioMixingServiceTests {
    @Test
    func mixesSystemAndMicrophoneIntoOneAudibleTrack() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokDownAudioMixingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let systemURL = folder.appendingPathComponent("system.wav")
        let microphoneURL = folder.appendingPathComponent("microphone.wav")
        let outputURL = folder.appendingPathComponent("meeting.m4a")

        try writeFixture(to: systemURL, audibleRange: 0..<7_000)
        try writeFixture(to: microphoneURL, audibleRange: 9_000..<16_000)

        let result = try await AudioMixingService().mix(
            systemAudioURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL
        )

        #expect(result == outputURL)

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)

        let outputFile = try AVAudioFile(forReading: outputURL)
        let frameCount = try #require(AVAudioFrameCount(exactly: outputFile.length))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: frameCount)
        )
        try outputFile.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let count = Int(buffer.frameLength)
        let quarter = count / 4

        #expect(peak(samples, in: 0..<quarter) > 0.05)
        #expect(peak(samples, in: (count - quarter)..<count) > 0.05)
    }

    private func writeFixture(to url: URL, audibleRange: Range<Int>) throws {
        let sampleRate = 16_000.0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
           let samples = buffer.floatChannelData?[0] else {
            throw FixtureError.couldNotCreateBuffer
        }

        buffer.frameLength = 16_000
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = audibleRange.contains(index)
                ? sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) * 0.2
                : 0
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func peak(_ samples: UnsafePointer<Float>, in range: Range<Int>) -> Float {
        range.reduce(0) { max($0, abs(samples[$1])) }
    }

    private enum FixtureError: Error {
        case couldNotCreateBuffer
    }
}
