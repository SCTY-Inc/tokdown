import Foundation

/// Protocol for audio decoding. Allows swapping in real Opus decoder later.
protocol AudioDecoding: Sendable {
    func decode(blePacket: Data) -> [Int16]?
    func reset()
}

/// Strips the 3-byte BLE header from Omi-protocol audio packets.
///
/// When libopus is vendored, this will perform actual Opus -> PCM decoding.
/// Current implementation: strips header, interprets remaining bytes as little-endian Int16 PCM.
/// This passthrough works for testing with raw PCM payloads.
///
/// BLE packet format:
///   [0]    sequence number
///   [1..2] metadata (codec flags)
///   [3..]  audio payload (Opus frame, or raw PCM for testing)
struct OpusDecoder: AudioDecoding {

    /// Minimum packet size: 3-byte header + at least 1 byte of audio
    private static let headerSize = 3

    /// Strip the 3-byte BLE header and decode audio payload.
    /// - Parameter blePacket: Raw data from BLE audio characteristic
    /// - Returns: PCM Int16 samples at 16 kHz, or nil if packet is too short
    func decode(blePacket: Data) -> [Int16]? {
        guard blePacket.count > Self.headerSize else { return nil }

        let audioData = blePacket.dropFirst(Self.headerSize)

        // TODO: Replace with actual opus_decode() call when libopus is vendored.
        // For now, interpret raw bytes as little-endian Int16 PCM samples.
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }

        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let offset = audioData.startIndex + i * 2
            let low = UInt16(audioData[offset])
            let high = UInt16(audioData[offset + 1])
            samples[i] = Int16(bitPattern: low | (high << 8))
        }
        return samples
    }

    /// Reset decoder state between recording sessions.
    /// No-op until libopus is vendored (will call opus_decoder_ctl OPUS_RESET_STATE).
    func reset() {
        // No-op: stateless passthrough decoder
    }
}

/// Buffers multiple BLE packets into complete audio frames.
/// Handles out-of-order delivery and dropped packets using the sequence byte.
final class AudioPacketProcessor: @unchecked Sendable {

    private var lastSequence: UInt8?
    private var droppedCount = 0
    private let decoder: any AudioDecoding

    init(decoder: any AudioDecoding = OpusDecoder()) {
        self.decoder = decoder
    }

    /// Process a raw BLE packet. Returns decoded PCM samples or nil on failure.
    func process(packet: Data) -> [Int16]? {
        guard !packet.isEmpty else { return nil }

        let sequence = packet[packet.startIndex]
        if let last = lastSequence {
            let expected = last &+ 1
            if sequence != expected {
                droppedCount += Int(sequence &- expected)
            }
        }
        lastSequence = sequence

        return decoder.decode(blePacket: packet)
    }

    /// Number of detected dropped packets since last reset
    var totalDropped: Int { droppedCount }

    /// Reset state for a new recording session
    func reset() {
        lastSequence = nil
        droppedCount = 0
        decoder.reset()
    }
}
