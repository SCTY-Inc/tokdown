import Foundation
import AVFoundation
import Opus

/// Decodes Opus audio frames into PCM Int16 samples using libopus.
///
/// Limitless Pendant streams Opus CELT-only mono 20ms frames (TOC 0xB8).
/// Each frame decodes to 320 PCM samples at 16kHz.
///
/// Important: a single decoder instance must be reused across the session.
/// Recreating per-packet causes crackling artifacts.
final class OpusStreamDecoder {

    private let decoder: Opus.Decoder

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            return nil
        }

        do {
            decoder = try Opus.Decoder(format: format)
        } catch {
            DebugLog.write("OpusStreamDecoder init failed: \(error)")
            return nil
        }
    }

    /// Decode a single Opus frame into PCM Int16 samples.
    func decode(opusFrame: Data) -> [Int16]? {
        guard !opusFrame.isEmpty else { return nil }

        do {
            let pcmBuffer = try decoder.decode(opusFrame)
            guard let channelData = pcmBuffer.int16ChannelData else { return nil }
            let count = Int(pcmBuffer.frameLength)
            guard count > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        } catch {
            return nil
        }
    }

    func reset() {
        try? decoder.reset()
    }
}
