import SwiftUI

/// Settings screen: GitHub PAT, recording mode, connection status, app version.
struct SettingsView: View {

    @Environment(SessionManager.self) var session
    @Environment(PendantBLE.self) var ble
    @State private var patInput: String = ""
    @State private var showPATSaved = false

    private let github = GitHubSync()

    var body: some View {
        @Bindable var session = session
        Form {
            Section("GitHub") {
                SecureField("Personal Access Token", text: $patInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()

                Button(action: savePAT) {
                    HStack {
                        Text("Save Token")
                        if showPATSaved {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .disabled(patInput.isEmpty)

                LabeledContent("Target") {
                    Text("amadad/agents")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Path") {
                    Text(session.settings.transcriptRepoPath)
                        .foregroundStyle(.secondary)
                }

                Toggle("Auto-push after recording", isOn: $session.settings.autoPushEnabled)

                Text("When auto-push is off, transcripts are still saved locally in the app's Documents/Transcripts folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Picker("Mode", selection: $session.settings.recordingMode) {
                    ForEach(SessionManager.RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
            }

            Section("Vocabulary Hints") {
                Text("Names, jargon, and terms to improve recognition accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(session.settings.vocabularyHints.indices, id: \.self) { i in
                    TextField("Term", text: $session.settings.vocabularyHints[i])
                }
                .onDelete { indices in
                    session.settings.vocabularyHints.remove(atOffsets: indices)
                }

                Button("Add Term") {
                    session.settings.vocabularyHints.append("")
                }
            }

            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(statusColor)
                        Text(statusText)
                    }
                }

                if let name = ble.peripheralName {
                    LabeledContent("Device") {
                        Text(name)
                    }
                }

                if let battery = ble.batteryLevel {
                    LabeledContent("Battery") {
                        Text("\(battery)%")
                    }
                }

                LabeledContent("Streaming") {
                    Text(ble.isStreaming ? "Active" : "Inactive")
                        .foregroundStyle(ble.isStreaming ? .green : .secondary)
                }
            }

            Section("About") {
                LabeledContent("App") {
                    Text("TokDown Mobile")
                }
                LabeledContent("Version") {
                    Text(appVersion)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            session.applySettings()
        }
        .onChange(of: session.settings.recordingMode) { _, newValue in
            session.setRecordingMode(newValue)
        }
    }

    // MARK: - Actions

    private func savePAT() {
        Task {
            do {
                try await github.savePAT(patInput)
                session.settings.hasGitHubPAT = true
                patInput = ""
                showPATSaved = true
                try? await Task.sleep(for: .seconds(2))
                showPATSaved = false
            } catch {
                session.lastError = "Couldn't save GitHub token: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Computed

    private var statusColor: Color {
        switch ble.connectionState {
        case .connected: .green
        case .scanning, .connecting: .orange
        case .disconnected: .red
        }
    }

    private var statusText: String {
        switch ble.connectionState {
        case .connected: "Connected"
        case .scanning: "Scanning"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return [version, build].compactMap { $0 }.joined(separator: " (") + (build != nil ? ")" : "")
    }
}
