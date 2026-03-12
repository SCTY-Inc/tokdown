import Foundation
import AppKit

struct SessionArtifacts {
    let audioURL: URL
    let transcriptURL: URL
}

final class StorageService {
    func sessionArtifacts(folderBase: URL, title: String, startTime: Date) throws -> SessionArtifacts {
        try FileManager.default.createDirectory(at: folderBase, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let baseName = "\(formatter.string(from: startTime))_\(sanitize(title))"

        return SessionArtifacts(
            audioURL: folderBase.appendingPathComponent("\(baseName).m4a"),
            transcriptURL: folderBase.appendingPathComponent("\(baseName).md")
        )
    }

    func writeTranscript(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func openFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func sanitize(_ text: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:<>*?\"|,\n")
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .prefix(60)
            .description
    }
}
