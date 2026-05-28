import Foundation
import AppKit

enum FileCleanupResult: Equatable, Sendable {
    case deleted
    case failed(String)
}

final class StorageService {
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(fileManager: FileManager = .default, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func temporaryAudioURL(startTime: Date) throws -> URL {
        let folder = temporaryAudioFolder
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let baseName = "\(datePrefix(for: startTime))_\(UUID().uuidString)"
        return folder.appendingPathComponent("\(baseName).m4a")
    }

    func transcriptURL(folderBase: URL, title: String, startTime: Date) throws -> URL {
        try fileManager.createDirectory(at: folderBase, withIntermediateDirectories: true)

        let baseName = nextAvailableBaseName(folderBase: folderBase, title: title, startTime: startTime, extensions: ["md"])
        return folderBase.appendingPathComponent("\(baseName).md")
    }

    func writeTranscript(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cleanupTemporaryAudioFiles() {
        guard let contents = try? fileManager.contentsOfDirectory(at: temporaryAudioFolder, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.pathExtension == "m4a" {
            deleteFile(url)
        }
    }

    @discardableResult
    func deleteFile(_ url: URL) -> FileCleanupResult {
        do {
            try fileManager.removeItem(at: url)
            return .deleted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func openFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private var temporaryAudioFolder: URL {
        temporaryDirectory
            .appendingPathComponent("TokDown", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
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
        "\(datePrefix(for: startTime))_\(sanitize(title))"
    }

    private func datePrefix(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter.string(from: date)
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
