import Foundation
import AppKit

struct SessionArtifacts: Sendable {
    let audioURL: URL
    let transcriptURL: URL
}

enum FileCleanupResult: Equatable, Sendable {
    case deleted
    case failed(String)
}

final class StorageService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func sessionArtifacts(folderBase: URL, title: String, startTime: Date) throws -> SessionArtifacts {
        try fileManager.createDirectory(at: folderBase, withIntermediateDirectories: true)

        let baseName = nextAvailableBaseName(folderBase: folderBase, title: title, startTime: startTime, extensions: ["m4a", "md"])

        return SessionArtifacts(
            audioURL: folderBase.appendingPathComponent("\(baseName).m4a"),
            transcriptURL: folderBase.appendingPathComponent("\(baseName).md")
        )
    }

    func transcriptURL(folderBase: URL, title: String, startTime: Date) -> URL {
        let baseName = nextAvailableBaseName(folderBase: folderBase, title: title, startTime: startTime, extensions: ["md"])
        return folderBase.appendingPathComponent("\(baseName).md")
    }

    func writeTranscript(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func deleteFile(_ url: URL) -> FileCleanupResult {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            return .deleted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func openFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func nextAvailableBaseName(folderBase: URL, title: String, startTime: Date, extensions: [String]) -> String {
        let root = makeBaseName(title: title, startTime: startTime)

        if isAvailable(baseName: root, folderBase: folderBase, extensions: extensions) {
            return root
        }

        var suffix = 2
        while true {
            let candidate = "\(root)-\(suffix)"
            if isAvailable(baseName: candidate, folderBase: folderBase, extensions: extensions) {
                return candidate
            }
            suffix += 1
        }
    }

    private func isAvailable(baseName: String, folderBase: URL, extensions: [String]) -> Bool {
        extensions.allSatisfy { ext in
            let url = folderBase.appendingPathComponent("\(baseName).\(ext)")
            return !fileManager.fileExists(atPath: url.path)
        }
    }

    private func makeBaseName(title: String, startTime: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "\(formatter.string(from: startTime))_\(sanitize(title))"
    }

    private func sanitize(_ text: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:<>*?\"|,\n")
        let sanitized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .prefix(60)
            .description

        return sanitized.isEmpty ? "Recording" : sanitized
    }
}
