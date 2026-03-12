import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject private var coordinator: MenuBarCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        Group {
            if coordinator.state == .recording {
                if let title = coordinator.activeTitle {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Button("Stop Recording") {
                    Task { await coordinator.stopRecording() }
                }
            } else if coordinator.state == .transcribing {
                Text("Transcribing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !coordinator.upcomingMeetings.isEmpty {
                    ForEach(coordinator.upcomingMeetings) { meeting in
                        Button("\(meeting.title)  \(meeting.timeWindowLabel)") {
                            Task { await coordinator.startRecording(title: meeting.title) }
                        }
                    }

                    Divider()

                    Button("Record without Meeting") {
                        Task { await coordinator.startRecording() }
                    }
                } else {
                    Button("Record") {
                        Task { await coordinator.startRecording() }
                    }
                }
            }

            Divider()

            Button("Open Folder") { coordinator.openRecordingsFolder() }

            Button("Settings") {
                SettingsWindowManager.shared.show(settingsStore: settingsStore)
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }

            if let msg = coordinator.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
        }
        .task {
            guard coordinator.state == .idle else { return }
            await coordinator.loadMeetings()
        }
    }
}

struct SettingsWindowView: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Save Folder", systemImage: "folder").font(.headline)
            Text(settingsStore.saveFolderURL.path)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(1)
            Button("Choose") { chooseSaveFolder() }

            Text("Upcoming meetings appear directly in the menu bar when calendar access is allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(14)
        .frame(width: 320)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Save Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.setSaveFolder(url)
        }
    }
}
