import Foundation
import Testing
@testable import TokDown

@Suite("OpusCaptureFile")
struct OpusCaptureFileTests {

    @Test("Round-trips length-prefixed Opus frames")
    func roundTripsFrames() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let frames = [
            Data([0xB8, 0x01, 0x02, 0x03]),
            Data([0xB8, 0x11, 0x12]),
            Data([0xB8, 0x21, 0x22, 0x23, 0x24])
        ]

        let capture = try OpusCaptureFile(baseDirectory: tempDirectory)
        for frame in frames {
            try capture.append(frame: frame)
        }
        let url = try capture.finalize()

        var decoded: [Data] = []
        try OpusCaptureFile.forEachFrame(at: url) { frame in
            decoded.append(frame)
        }

        #expect(decoded == frames)
    }
}
