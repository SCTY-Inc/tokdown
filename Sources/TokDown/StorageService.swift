import Foundation
import AppKit

struct SessionArtifacts: Sendable {
    let audioURL: URL
    let transcriptURL: URL
}

final class StorageService {
    func sessionArtifacts(folderBase: URL, title: String, startTime: Date) throws -> SessionArtifacts {
        try FileManager.default.createDirectory(at: folderBase, withIntermediateDirectories: true)

        let baseName = makeBaseName(title: title, startTime: startTime)

        return SessionArtifacts(
            audioURL: folderBase.appendingPathComponent("\(baseName).m4a"),
            transcriptURL: folderBase.appendingPathComponent("\(baseName).md")
        )
    }

    func transcriptURL(folderBase: URL, title: String, startTime: Date) -> URL {
        folderBase.appendingPathComponent("\(makeBaseName(title: title, startTime: startTime)).md")
    }

    func writeTranscript(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func deleteFile(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func openFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func makeBaseName(title: String, startTime: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "\(formatter.string(from: startTime))_\(sanitize(title))"
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
