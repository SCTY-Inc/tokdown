import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject private var coordinator: MenuBarCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
            Button("Record") {
                Task { await coordinator.startRecording() }
            }

            if !coordinator.upcomingMeetings.isEmpty {
                Divider()
                ForEach(coordinator.upcomingMeetings) { meeting in
                    Button("\(meeting.title)  \(meeting.timeWindowLabel)") {
                        Task { await coordinator.startRecording(title: meeting.title) }
                    }
                }
            }
        }

        Divider()

        Button("Open Folder") { coordinator.openRecordingsFolder() }

        Button("Settings") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit") { NSApplication.shared.terminate(nil) }

        if let msg = coordinator.statusMessage {
            Text(msg).font(.caption).foregroundStyle(.red)
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

            Divider()

            Label("Audio Source", systemImage: "waveform").font(.headline)
            Picker("", selection: Binding(
                get: { settingsStore.settings.audioSource },
                set: { settingsStore.setAudioSource($0) }
            )) {
                ForEach(AudioSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settingsStore.settings.audioSource == .systemAudio {
                Text("Captures all system audio (meetings, videos, music).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Records from microphone input.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
