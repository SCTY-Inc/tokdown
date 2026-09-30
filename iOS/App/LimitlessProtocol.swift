import Foundation
import os

// MARK: - Minimal Protobuf Encoding (no external deps)

/// Lightweight protobuf wire-format encoder for Limitless Pendant commands.
/// Only supports varint and length-delimited fields — sufficient for the pendant protocol.
enum Protobuf {

    static func varint(_ value: UInt64) -> Data {
        var v = value
        var bytes = Data()
        while v > 0x7F {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
        return bytes
    }

    static func fieldVarint(_ fieldNumber: Int, _ value: UInt64) -> Data {
        let tag = UInt64(fieldNumber << 3 | 0) // wire type 0
        return varint(tag) + varint(value)
    }

    static func fieldBytes(_ fieldNumber: Int, _ data: Data) -> Data {
        let tag = UInt64(fieldNumber << 3 | 2) // wire type 2
        return varint(tag) + varint(UInt64(data.count)) + data
    }

    static func fieldMessage(_ fieldNumber: Int, _ content: Data) -> Data {
        fieldBytes(fieldNumber, content)
    }

    // MARK: - Decoding

    struct Field {
        let number: Int
        let wireType: Int
        let varintValue: UInt64
        let bytesValue: Data
    }

    /// Parse all fields from a protobuf-encoded message.
    static func decode(_ data: Data) -> [Field] {
        var fields: [Field] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard let (field, nextOffset) = readField(data, from: offset) else {
                return []
            }
            fields.append(field)
            offset = nextOffset
        }
        return fields
    }

    private static func readField(_ data: Data, from offset: Data.Index) -> (Field, Data.Index)? {
        guard let (tag, valueOffset) = readVarint(data, from: offset) else { return nil }
        guard let wireType = Int(exactly: tag & 0x07),
              let fieldNumber = Int(exactly: tag >> 3) else {
            return nil
        }

        switch wireType {
        case 0:
            guard let (value, nextOffset) = readVarint(data, from: valueOffset) else { return nil }
            return (Field(number: fieldNumber, wireType: wireType, varintValue: value, bytesValue: Data()), nextOffset)
        case 2:
            guard let (bytes, nextOffset) = readLengthDelimited(data, from: valueOffset) else { return nil }
            return (Field(number: fieldNumber, wireType: wireType, varintValue: 0, bytesValue: bytes), nextOffset)
        default:
            return nil
        }
    }

    private static func readLengthDelimited(_ data: Data, from offset: Data.Index) -> (Data, Data.Index)? {
        guard let (length, valueOffset) = readVarint(data, from: offset) else { return nil }
        let remainingBytes = data.distance(from: valueOffset, to: data.endIndex)
        guard length <= UInt64(remainingBytes),
              let endOffset = data.index(valueOffset, offsetBy: Int(length), limitedBy: data.endIndex) else {
            return nil
        }
        return (Data(data[valueOffset..<endOffset]), endOffset)
    }

    private static func readVarint(_ data: Data, from offset: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var idx = offset
        while idx < data.endIndex {
            let byte = data[idx]
            result |= UInt64(byte & 0x7F) << shift
            idx = data.index(after: idx)
            if byte & 0x80 == 0 { return (result, idx) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

// MARK: - Limitless Pendant Commands

/// Builds protobuf-encoded BLE commands for the Limitless Pendant.
/// TX characteristic: 632DE002-604C-446B-A80F-7963E950F3FB
enum LimitlessCommand {

    private static let _messageIndex = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func reset() { _messageIndex.withLock { $0 = 0 } }

    /// Build the BLE wrapper around a payload.
    /// Fields: 1=index, 2=sequence(0), 3=numFragments(1), 4=payload
    private static func wrapBLE(_ payload: Data) -> Data {
        let idx = _messageIndex.withLock { val -> UInt64 in
            let current = val; val += 1; return current
        }
        return Protobuf.fieldVarint(1, idx)
             + Protobuf.fieldVarint(2, 0)
             + Protobuf.fieldVarint(3, 1)
             + Protobuf.fieldBytes(4, payload)
    }

    /// RequestData trailer: field 30 with sub-fields request_id and type.
    private static func requestData(requestId: UInt64 = 1) -> Data {
        let inner = Protobuf.fieldVarint(1, requestId) + Protobuf.fieldVarint(2, 0)
        return Protobuf.fieldMessage(30, inner)
    }

    /// Time sync command — must be sent before enabling data stream.
    /// Payload field 6 = Message(field 1 = timestamp_ms)
    static func timeSync() -> Data {
        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let inner = Protobuf.fieldVarint(1, timestampMs)
        let payload = Protobuf.fieldMessage(6, inner) + requestData()
        return wrapBLE(payload)
    }

    /// Enable real-time data streaming.
    /// Payload field 8 = Message(field 1 = batchMode(0), field 2 = realTimeMode(1))
    static func enableDataStream() -> Data {
        let inner = Protobuf.fieldVarint(1, 0) + Protobuf.fieldVarint(2, 1)
        let payload = Protobuf.fieldMessage(8, inner) + requestData(requestId: 2)
        return wrapBLE(payload)
    }

    /// Disable real-time data streaming (stop audio from pendant).
    /// Payload field 8 = Message(field 1 = batchMode(0), field 2 = realTimeMode(0))
    static func disableDataStream() -> Data {
        let inner = Protobuf.fieldVarint(1, 0) + Protobuf.fieldVarint(2, 0)
        let payload = Protobuf.fieldMessage(8, inner) + requestData(requestId: 3)
        return wrapBLE(payload)
    }

    /// Acknowledge processed data index for flow control.
    /// Payload field 7 = Message(field 1 = index)
    static func ackData(index: UInt64) -> Data {
        let inner = Protobuf.fieldVarint(1, index)
        let payload = Protobuf.fieldMessage(7, inner)
        return wrapBLE(payload)
    }
}

// MARK: - Fragment Reassembly

/// Reassembles fragmented BLE notifications into complete protobuf payloads.
/// Each notification has: field 1=messageIndex, field 2=fragmentSeq, field 3=totalFragments, field 4=payload
final class FragmentReassembler {

    private struct PendingMessage {
        let totalFragments: Int
        var fragments: [Int: Data] = [:]
        let createdAt: Date = Date()
    }

    private var pending: [UInt64: PendingMessage] = [:]

    /// Process a raw BLE notification. Returns completed payload when all fragments received.
    func process(notification data: Data) -> Data? {
        let fields = Protobuf.decode(data)

        var messageIndex: UInt64?
        var fragmentSeq: Int?
        var totalFragments: Int?
        var payload: Data?

        for field in fields {
            switch field.number {
            case 1: messageIndex = field.varintValue
            case 2:
                guard let seq = Int(exactly: field.varintValue) else { return nil }
                fragmentSeq = seq
            case 3:
                guard let total = Int(exactly: field.varintValue) else { return nil }
                totalFragments = total
            case 4: payload = field.bytesValue
            default: break
            }
        }

        guard let messageIndex,
              let fragmentSeq,
              let totalFragments,
              let payload,
              totalFragments > 0,
              fragmentSeq >= 0,
              fragmentSeq < totalFragments else {
            return nil
        }

        if totalFragments == 1 {
            return payload
        }

        if let existing = pending[messageIndex], existing.totalFragments != totalFragments {
            pending.removeValue(forKey: messageIndex)
        }

        var message = pending[messageIndex] ?? PendingMessage(totalFragments: totalFragments)
        guard message.totalFragments == totalFragments else { return nil }
        message.fragments[fragmentSeq] = payload
        pending[messageIndex] = message

        let expectedFragments = Set(0..<message.totalFragments)
        guard Set(message.fragments.keys) == expectedFragments else {
            evictStaleMessages()
            return nil
        }

        pending.removeValue(forKey: messageIndex)
        var assembled = Data()
        for index in 0..<message.totalFragments {
            guard let fragment = message.fragments[index] else { return nil }
            assembled.append(fragment)
        }
        return assembled
    }

    func reset() {
        pending.removeAll()
    }

    private func evictStaleMessages() {
        let cutoff = Date().addingTimeInterval(-5)
        pending = pending.filter { $0.value.createdAt > cutoff }
    }
}

// MARK: - Opus Frame Extractor

/// Extracts Opus frames from a reassembled Limitless protobuf payload.
///
/// Actual payload structure (from device captures):
///   field 2 (message): audio container
///     field 1: flags/type
///     field 2: codec info
///     field 3: ?
///     field 4: counter
///     field 5: counter
///     field 6 (repeated bytes): individual Opus frames
enum OpusFrameExtractor {

    /// Valid Opus TOC bytes for the Limitless Pendant
    private static let validTOCBytes: Set<UInt8> = [0xB8, 0x78, 0xF8, 0xB0, 0x70, 0xF0]

    /// Extract all Opus frames from a reassembled payload.
    static func extract(from payload: Data) -> [Data] {
        var frames: [Data] = []

        // Try extracting from all length-delimited fields recursively
        extractFrames(from: payload, into: &frames, depth: 0)

        return frames
    }

    private static func extractFrames(from data: Data, into frames: inout [Data], depth: Int) {
        guard depth < 5 else { return }

        let fields = Protobuf.decode(data)

        // No per-call logging — too much overhead

        for field in fields {
            guard field.wireType == 2, !field.bytesValue.isEmpty else { continue }

            let bytes = field.bytesValue

            // At depth >= 3, we're inside individual audio entries.
            // Look for the raw audio bytes in the innermost length-delimited field.
            if depth >= 3, bytes.count >= 2, bytes.count <= 400 {
                if let toc = bytes.first, validTOCBytes.contains(toc) {
                    frames.append(bytes)
                    continue
                }
            }

            // Keep recursing into nested messages
            if bytes.count > 4 {
                extractFrames(from: bytes, into: &frames, depth: depth + 1)
            }
        }
    }
}
