import Foundation
import Testing
@testable import TokDown

// MARK: - Protobuf encoding/decoding

@Suite("Protobuf")
struct ProtobufTests {

    @Test("varint encodes single-byte value")
    func varintSingleByte() {
        #expect(Protobuf.varint(1) == Data([0x01]))
        #expect(Protobuf.varint(0) == Data([0x00]))
        #expect(Protobuf.varint(127) == Data([0x7F]))
    }

    @Test("varint encodes multi-byte value")
    func varintMultiByte() {
        // 128 = 0x80 -> 0x80, 0x01 in base-128
        #expect(Protobuf.varint(128) == Data([0x80, 0x01]))
        // 300 = 0x12C -> 0xAC, 0x02
        #expect(Protobuf.varint(300) == Data([0xAC, 0x02]))
    }

    @Test("decode round-trips varint field")
    func decodeVarintField() {
        let data = Protobuf.fieldVarint(1, 42)
        let fields = Protobuf.decode(data)
        #expect(fields.count == 1)
        #expect(fields[0].number == 1)
        #expect(fields[0].wireType == 0)
        #expect(fields[0].varintValue == 42)
    }

    @Test("decode round-trips bytes field")
    func decodeBytesField() {
        let payload = Data([0x01, 0x02, 0x03])
        let data = Protobuf.fieldBytes(2, payload)
        let fields = Protobuf.decode(data)
        #expect(fields.count == 1)
        #expect(fields[0].number == 2)
        #expect(fields[0].wireType == 2)
        #expect(fields[0].bytesValue == payload)
    }

    @Test("decode handles multiple fields")
    func decodeMultipleFields() {
        let data = Protobuf.fieldVarint(1, 7)
            + Protobuf.fieldVarint(2, 3)
            + Protobuf.fieldBytes(4, Data([0xAA, 0xBB]))
        let fields = Protobuf.decode(data)
        #expect(fields.count == 3)
        #expect(fields[0].number == 1)
        #expect(fields[1].number == 2)
        #expect(fields[2].number == 4)
    }

    @Test("decode returns empty for empty data")
    func decodeEmpty() {
        #expect(Protobuf.decode(Data()).isEmpty)
    }

    @Test("decode fails closed on truncated length-delimited field")
    func decodeTruncated() {
        // tag for field 1 wire type 2 = 0x0A, length claims 5 bytes but only 2 follow
        let data = Data([0x0A, 0x05, 0x01, 0x02])
        #expect(Protobuf.decode(data).isEmpty)
    }

    @Test("fieldMessage wraps content as bytes field")
    func fieldMessage() {
        let inner = Protobuf.fieldVarint(1, 99)
        let outer = Protobuf.fieldMessage(3, inner)
        let fields = Protobuf.decode(outer)
        #expect(fields.count == 1)
        #expect(fields[0].number == 3)
        #expect(fields[0].wireType == 2)
        // The decoded bytes should itself decode to the inner field
        let innerFields = Protobuf.decode(fields[0].bytesValue)
        #expect(innerFields.count == 1)
        #expect(innerFields[0].number == 1)
        #expect(innerFields[0].varintValue == 99)
    }
}

// MARK: - FragmentReassembler

@Suite("FragmentReassembler")
struct FragmentReassemblerTests {

    /// Build a BLE notification in the pendant wire format:
    /// field 1=messageIndex, field 2=fragmentSeq, field 3=totalFragments, field 4=payload
    private func notification(idx: UInt64, seq: Int, total: Int, payload: Data) -> Data {
        Protobuf.fieldVarint(1, idx)
            + Protobuf.fieldVarint(2, UInt64(seq))
            + Protobuf.fieldVarint(3, UInt64(total))
            + Protobuf.fieldBytes(4, payload)
    }

    @Test("single fragment returns payload immediately")
    func singleFragment() {
        let r = FragmentReassembler()
        let payload = Data([0xAA, 0xBB, 0xCC])
        let result = r.process(notification: notification(idx: 1, seq: 0, total: 1, payload: payload))
        #expect(result == payload)
    }

    @Test("two fragments in order assemble correctly")
    func twoFragmentsInOrder() {
        let r = FragmentReassembler()
        let p1 = Data([0x01, 0x02])
        let p2 = Data([0x03, 0x04])
        #expect(r.process(notification: notification(idx: 1, seq: 0, total: 2, payload: p1)) == nil)
        #expect(r.process(notification: notification(idx: 1, seq: 1, total: 2, payload: p2)) == p1 + p2)
    }

    @Test("three fragments out of sequence assemble correctly")
    func threeFragmentsOutOfOrder() {
        let r = FragmentReassembler()
        let parts = [Data([0xAA]), Data([0xBB]), Data([0xCC])]
        // Deliver in order: 0, 2, 1
        #expect(r.process(notification: notification(idx: 2, seq: 0, total: 3, payload: parts[0])) == nil)
        #expect(r.process(notification: notification(idx: 2, seq: 2, total: 3, payload: parts[2])) == nil)
        let result = r.process(notification: notification(idx: 2, seq: 1, total: 3, payload: parts[1]))
        #expect(result == parts[0] + parts[1] + parts[2])
    }

    @Test("duplicate fragment is idempotent")
    func duplicateFragment() {
        let r = FragmentReassembler()
        let p1 = Data([0x01])
        let p2 = Data([0x02])
        _ = r.process(notification: notification(idx: 3, seq: 0, total: 2, payload: p1))
        // Send fragment 0 again — should overwrite with same data, not corrupt
        _ = r.process(notification: notification(idx: 3, seq: 0, total: 2, payload: p1))
        let result = r.process(notification: notification(idx: 3, seq: 1, total: 2, payload: p2))
        #expect(result == p1 + p2)
    }

    @Test("out-of-range fragmentSeq is rejected")
    func outOfRangeSeq() {
        let r = FragmentReassembler()
        // seq == total means index is one past the end
        let n = notification(idx: 4, seq: 2, total: 2, payload: Data([0x01]))
        #expect(r.process(notification: n) == nil)
    }

    @Test("negative fragmentSeq is rejected")
    func negativeSeq() {
        let r = FragmentReassembler()
        // Encode seq as a large UInt64 that would wrap to negative if treated as Int
        let data = Protobuf.fieldVarint(1, 5)
            + Protobuf.fieldVarint(2, UInt64.max)   // seq = UInt64.max, Int(UInt64.max) = -1
            + Protobuf.fieldVarint(3, 2)
            + Protobuf.fieldBytes(4, Data([0x01]))
        #expect(r.process(notification: data) == nil)
    }

    @Test("malformed protobuf returns nil")
    func malformedProtobuf() {
        let r = FragmentReassembler()
        // Random bytes that don't form valid fields
        #expect(r.process(notification: Data([0xFF, 0xFF, 0xFF])) == nil)
    }

    @Test("missing required fields returns nil")
    func missingRequiredFields() {
        let r = FragmentReassembler()
        // Only field 1 (messageIndex), missing seq/total/payload
        let data = Protobuf.fieldVarint(1, 1)
        #expect(r.process(notification: data) == nil)
    }

    @Test("totalFragments mismatch discards pending and restarts")
    func totalFragmentsMismatch() {
        let r = FragmentReassembler()
        // Start with total=2
        _ = r.process(notification: notification(idx: 5, seq: 0, total: 2, payload: Data([0x01])))
        // Same messageIndex but now claims total=3 — discards previous, starts fresh
        _ = r.process(notification: notification(idx: 5, seq: 0, total: 3, payload: Data([0x02])))
        _ = r.process(notification: notification(idx: 5, seq: 1, total: 3, payload: Data([0x03])))
        let result = r.process(notification: notification(idx: 5, seq: 2, total: 3, payload: Data([0x04])))
        #expect(result == Data([0x02, 0x03, 0x04]))
    }

    @Test("reset clears all pending messages")
    func resetClearsPending() {
        let r = FragmentReassembler()
        // Begin a 2-fragment message
        _ = r.process(notification: notification(idx: 6, seq: 0, total: 2, payload: Data([0x01])))
        r.reset()
        // Second fragment arrives after reset — incomplete without first fragment
        let result = r.process(notification: notification(idx: 6, seq: 1, total: 2, payload: Data([0x02])))
        #expect(result == nil)
    }

    @Test("multiple concurrent message indices are independent")
    func concurrentMessages() {
        let r = FragmentReassembler()
        let pA0 = Data([0xA0])
        let pA1 = Data([0xA1])
        let pB0 = Data([0xB0])
        let pB1 = Data([0xB1])
        // Interleave fragments from two different message indices
        _ = r.process(notification: notification(idx: 10, seq: 0, total: 2, payload: pA0))
        _ = r.process(notification: notification(idx: 11, seq: 0, total: 2, payload: pB0))
        let resultA = r.process(notification: notification(idx: 10, seq: 1, total: 2, payload: pA1))
        let resultB = r.process(notification: notification(idx: 11, seq: 1, total: 2, payload: pB1))
        #expect(resultA == pA0 + pA1)
        #expect(resultB == pB0 + pB1)
    }
}

// MARK: - OpusFrameExtractor

@Suite("OpusFrameExtractor")
struct OpusFrameExtractorTests {

    /// Build a 4-level nested payload so frames appear at depth 3 in extractFrames.
    /// Structure: fieldBytes(2, fieldBytes(6, fieldBytes(3, fieldBytes(4, frame))))
    private func makePayload(frame: Data) -> Data {
        let d3 = Protobuf.fieldBytes(4, frame)   // depth 3 parent's content
        let d2 = Protobuf.fieldBytes(3, d3)      // depth 2 parent's content
        let d1 = Protobuf.fieldBytes(6, d2)      // depth 1 parent's content
        return Protobuf.fieldBytes(2, d1)        // depth 0 payload
    }

    @Test("extracts frame with TOC byte 0xB8")
    func extractsTOC_B8() {
        var frame = Data(repeating: 0, count: 10)
        frame[0] = 0xB8
        let frames = OpusFrameExtractor.extract(from: makePayload(frame: frame))
        #expect(frames.count == 1)
        #expect(frames[0] == frame)
    }

    @Test("extracts frame with TOC byte 0x78")
    func extractsTOC_78() {
        var frame = Data(repeating: 0, count: 10)
        frame[0] = 0x78
        let frames = OpusFrameExtractor.extract(from: makePayload(frame: frame))
        #expect(frames.count == 1)
    }

    @Test("ignores bytes with invalid TOC byte")
    func ignoresInvalidTOC() {
        var frame = Data(repeating: 0, count: 10)
        frame[0] = 0x01  // not a valid Limitless Opus TOC byte
        let frames = OpusFrameExtractor.extract(from: makePayload(frame: frame))
        #expect(frames.isEmpty)
    }

    @Test("empty payload returns no frames")
    func emptyPayload() {
        #expect(OpusFrameExtractor.extract(from: Data()).isEmpty)
    }

    @Test("frame shorter than 2 bytes is not extracted")
    func frameTooShort() {
        let frame = Data([0xB8])  // only 1 byte; count < 2
        let frames = OpusFrameExtractor.extract(from: makePayload(frame: frame))
        #expect(frames.isEmpty)
    }

    @Test("frame larger than 400 bytes is not extracted")
    func frameTooLong() {
        var frame = Data(repeating: 0, count: 401)
        frame[0] = 0xB8
        let frames = OpusFrameExtractor.extract(from: makePayload(frame: frame))
        #expect(frames.isEmpty)
    }
}

// MARK: - LimitlessCommand

@Suite("LimitlessCommand")
struct LimitlessCommandTests {

    @Test("timeSync encodes BLE wrapper with fields 1-4")
    func timeSyncHasWrapper() {
        LimitlessCommand.reset()
        let data = LimitlessCommand.timeSync()
        let fields = Protobuf.decode(data)
        let numbers = Set(fields.map(\.number))
        #expect(numbers.contains(1))  // messageIndex
        #expect(numbers.contains(2))  // sequence
        #expect(numbers.contains(3))  // numFragments
        #expect(numbers.contains(4))  // payload
    }

    @Test("enableDataStream encodes BLE wrapper")
    func enableDataStreamHasWrapper() {
        LimitlessCommand.reset()
        let data = LimitlessCommand.enableDataStream()
        let fields = Protobuf.decode(data)
        #expect(fields.map(\.number).contains(4))
    }

    @Test("disableDataStream encodes BLE wrapper")
    func disableDataStreamHasWrapper() {
        LimitlessCommand.reset()
        let data = LimitlessCommand.disableDataStream()
        let fields = Protobuf.decode(data)
        #expect(fields.map(\.number).contains(4))
    }

    @Test("messageIndex increments across calls")
    func messageIndexIncrements() {
        LimitlessCommand.reset()
        let d1 = LimitlessCommand.timeSync()
        let d2 = LimitlessCommand.timeSync()
        let d3 = LimitlessCommand.enableDataStream()
        let idx1 = Protobuf.decode(d1).first(where: { $0.number == 1 })?.varintValue
        let idx2 = Protobuf.decode(d2).first(where: { $0.number == 1 })?.varintValue
        let idx3 = Protobuf.decode(d3).first(where: { $0.number == 1 })?.varintValue
        #expect(idx1 == 0)
        #expect(idx2 == 1)
        #expect(idx3 == 2)
    }

    @Test("timeSync sequence field is 0")
    func timeSyncSequenceIsZero() {
        LimitlessCommand.reset()
        let data = LimitlessCommand.timeSync()
        let seq = Protobuf.decode(data).first(where: { $0.number == 2 })?.varintValue
        #expect(seq == 0)
    }

    @Test("timeSync numFragments is 1")
    func timeSyncNumFragmentsIsOne() {
        LimitlessCommand.reset()
        let data = LimitlessCommand.timeSync()
        let frags = Protobuf.decode(data).first(where: { $0.number == 3 })?.varintValue
        #expect(frags == 1)
    }
}
