import Foundation

/// Writes debug lines to Documents/debug.log for retrieval via devicectl.
enum DebugLog {
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var lineCount = 0

    static func write(_ message: String) {
        if fileHandle == nil {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let url = docs.appendingPathComponent("debug.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: url)
        }
        guard let fh = fileHandle else { return }
        lineCount += 1
        // Only log first 200 lines to avoid filling storage
        guard lineCount <= 200 else { return }
        let line = "\(lineCount): \(message)\n"
        if let data = line.data(using: .utf8) {
            fh.seekToEndOfFile()
            fh.write(data)
        }
    }
}
