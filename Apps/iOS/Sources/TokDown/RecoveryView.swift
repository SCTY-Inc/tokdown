import SwiftUI

/// Browse and retry failed Low Power transcription files saved in Documents/TranscriptionRecovery.
struct RecoveryView: View {

    @Environment(SessionManager.self) var session
    @State private var files: [URL] = []
    @State private var retryingID: URL? = nil
    @State private var retryResults: [URL: String] = [:]  // URL -> error message (nil key = success)

    var body: some View {
        Group {
            if files.isEmpty {
                ContentUnavailableView(
                    "No Recovery Files",
                    systemImage: "checkmark.circle",
                    description: Text("Captured audio that couldn't be transcribed would appear here.")
                )
            } else {
                List {
                    Section {
                        Text("These are Opus audio captures saved when transcription failed. Tap Retry to attempt transcription again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(files, id: \.absoluteString) { url in
                        recoveryRow(url)
                    }
                }
            }
        }
        .navigationTitle("Recovery Files")
        .onAppear { reload() }
    }

    private func reload() {
        files = session.recoveryFiles()
    }

    @ViewBuilder
    private func recoveryRow(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let size = fileSize(url) {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if retryingID == url {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button("Retry") {
                        retryFile(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(retryingID != nil)
                }
            }

            if let errorMessage = retryResults[url] {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                session.deleteRecovery(at: url)
                reload()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func retryFile(_ url: URL) {
        retryingID = url
        retryResults.removeValue(forKey: url)
        Task {
            let error = await session.retryRecovery(at: url)
            retryingID = nil
            if let error {
                retryResults[url] = error
            } else {
                reload()
            }
        }
    }

    private func fileSize(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        let kb = Double(size) / 1024
        return kb < 1024
            ? String(format: "%.0f KB", kb)
            : String(format: "%.1f MB", kb / 1024)
    }
}
