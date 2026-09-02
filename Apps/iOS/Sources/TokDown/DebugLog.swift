import Foundation

/// Writes debug lines to Documents/debug.log for retrieval via devicectl.
/// No-op in release builds.
enum DebugLog {
    #if DEBUG
    private static let lock = NSLock()
    // Invariant: all access wrapped in `lock.lock()/unlock()` — see `write(_:)` below.
    // Removal plan: replace with Mutex or an actor when DebugLog is allowed to be async.
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var lineCount = 0

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        if fileHandle == nil {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }
            let url = docs.appendingPathComponent("debug.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: url)
        }
        guard let fh = fileHandle else { return }
        lineCount += 1
        guard lineCount <= 200 else { return }
        let line = "\(lineCount): \(message)\n"
        if let data = line.data(using: .utf8) {
            fh.seekToEndOfFile()
            fh.write(data)
        }
    }
    #else
    @inline(__always)
    static func write(_ message: String) {}
    #endif
}
