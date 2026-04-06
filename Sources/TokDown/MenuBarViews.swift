import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @Environment(MenuBarCoordinator.self) private var coordinator
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        Group {
            if coordinator.state == .recording {
                if let title = coordinator.activeTitle {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Button(action: { Task { await coordinator.stopRecording() } }) {
                    Label("Stop Recording", systemImage: "stop.circle")
                }
            } else if coordinator.state == .transcribing {
                Label {
                    Text("Transcribing...")
                } icon: {
                    Image(systemName: "text.badge.checkmark")
                }
                .foregroundStyle(.secondary)
            } else {
                if !coordinator.upcomingMeetings.isEmpty {
                    ForEach(coordinator.upcomingMeetings) { meeting in
                        Button(action: {
                            Task { await coordinator.startRecording(meeting: meeting) }
                        }) {
                            Label {
                                Text("\(meeting.title)  \(meeting.timeWindowLabel)")
                            } icon: {
                                Image(systemName: "calendar")
                            }
                        }
                    }

                    Divider()
                }

                Button(action: { Task { await coordinator.startRecording() } }) {
                    Label("Record", systemImage: "waveform")
                }
            }

            Divider()

            Button(action: { coordinator.openRecordingsFolder() }) {
                Label("Open Folder", systemImage: "folder")
            }

            Button(action: {
                SettingsWindowManager.shared.show(settingsStore: settingsStore)
            }) {
                Label("Settings", systemImage: "gear")
            }

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "xmark.circle")
            }

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
    var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Save Folder", systemImage: "folder")
                    .font(.headline)

                Text(settingsStore.saveFolderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Button("Choose Folder…") { chooseSaveFolder() }

            Text("Upcoming meetings appear directly in the menu bar when calendar access is allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
