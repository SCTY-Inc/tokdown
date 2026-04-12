import Foundation

/// Persists raw Opus frames for deferred transcription.
///
/// Frames are written as a simple length-prefixed stream:
///   [UInt32 little-endian byte count][frame bytes]...
///
/// SessionManager owns this type on the main actor, so no additional
/// synchronization is required here.
final class OpusCaptureFile {

    enum CaptureError: Error {
        case writerClosed
        case invalidFrameLengthHeader(Int)
        case truncatedFrame(expected: Int, actual: Int)
    }

    let url: URL
    private var handle: FileHandle?

    init(baseDirectory: URL? = nil) throws {
        let directory = (baseDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("TokDownCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("opusframes")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(frame: Data) throws {
        guard let handle else { throw CaptureError.writerClosed }
        try handle.write(contentsOf: encodedLength(frame.count))
        try handle.write(contentsOf: frame)
    }

    @discardableResult
    func finalize() throws -> URL {
        if let handle {
            try handle.close()
            self.handle = nil
        }
        return url
    }

    func delete() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    static func forEachFrame(at url: URL, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while true {
            guard let header = try handle.read(upToCount: 4) else { break }
            if header.isEmpty { break }
            guard header.count == 4 else {
                throw CaptureError.invalidFrameLengthHeader(header.count)
            }

            let length = decodedLength(from: header)
            guard let frame = try handle.read(upToCount: length) else {
                throw CaptureError.truncatedFrame(expected: length, actual: 0)
            }
            guard frame.count == length else {
                throw CaptureError.truncatedFrame(expected: length, actual: frame.count)
            }

            try body(frame)
        }
    }

    private func encodedLength(_ value: Int) -> Data {
        var length = UInt32(value).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }

    private static func decodedLength(from data: Data) -> Int {
        let bytes = Array(data)
        let value = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return Int(value)
    }
}
