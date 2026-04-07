import SwiftUI

/// Main screen: pendant status, recording controls, upcoming meetings, recent transcripts.
struct ContentView: View {

    @Environment(SessionManager.self) var session
    @Environment(PendantBLE.self) var ble
    @Environment(TranscriptionService.self) var transcription
    @Environment(CalendarService.self) var calendar

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pendantStatusBar
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if session.state == .recording {
                            recordingCard
                        } else if session.state == .transcribing || session.state == .pushing {
                            processingCard
                        } else {
                            recordButton
                        }

                        if session.state == .idle {
                            upcomingSection
                        }

                        recentSection

                        if let error = session.lastError {
                            errorBanner(error)
                        }
                    }
                    .padding()
                }

                Spacer(minLength: 0)

                NavigationLink(destination: SettingsView()) {
                    Label("Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("TokDown")
        }
    }

    // MARK: - Pendant Status Bar

    private var pendantStatusBar: some View {
        HStack {
            connectionDot
            Text(connectionLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if let battery = ble.batteryLevel {
                Label("\(battery)%", systemImage: batteryIcon(battery))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var connectionDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(connectionColor)
    }

    private var connectionLabel: String {
        switch ble.connectionState {
        case .connected:
            ble.peripheralName ?? "Connected"
        case .scanning:
            "Scanning..."
        case .connecting:
            "Connecting..."
        case .disconnected:
            "Disconnected"
        }
    }

    private var connectionColor: Color {
        switch ble.connectionState {
        case .connected: .green
        case .scanning, .connecting: .orange
        case .disconnected: .red
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 0..<25: "battery.25"
        case 25..<50: "battery.50"
        case 50..<75: "battery.75"
        default: "battery.100"
        }
    }

    // MARK: - Recording Card

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                Text("REC")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(formattedDuration)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !session.currentTitle.isEmpty {
                Text(session.currentTitle)
                    .font(.body)
            }

            if !transcription.fullText.isEmpty {
                Text(transcription.fullText.suffix(200))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Button(action: { session.stopRecording() }) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.red.opacity(0.08))
        )
    }

    private var formattedDuration: String {
        let total = Int(session.recordingDuration)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Processing Card

    private var processingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(session.state == .transcribing ? "Transcribing..." : "Pushing to GitHub...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.secondary.opacity(0.08))
        )
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button(action: { session.startRecording() }) {
            Label("Record", systemImage: "waveform")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(ble.connectionState != .connected)
    }

    // MARK: - Upcoming Meetings

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Upcoming", systemImage: "calendar")
                .font(.headline)

            if calendar.upcomingMeetings.isEmpty {
                Text("No upcoming meetings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendar.upcomingMeetings) { meeting in
                    Button(action: { session.startRecording(meeting: meeting) }) {
                        HStack {
                            Image(systemName: "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            Text(meetingTime(meeting.startDate))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(meeting.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(ble.connectionState != .connected)
                }
            }
        }
    }

    // MARK: - Recent Transcripts

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent", systemImage: "clock")
                .font(.headline)

            if session.recentTranscripts.isEmpty {
                Text("No recent transcripts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.recentTranscripts) { transcript in
                    NavigationLink(destination: TranscriptDetailView(transcript: transcript)) {
                        HStack {
                            Image(systemName: transcript.pushed
                                  ? "checkmark.circle.fill"
                                  : "checkmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(transcript.pushed ? .green : .secondary)
                            Text(meetingTime(transcript.date))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(transcript.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.yellow.opacity(0.1))
        )
    }

    // MARK: - Helpers

    private func meetingTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Transcript Detail View

struct TranscriptDetailView: View {
    let transcript: SessionManager.RecentTranscript
    @Environment(SessionManager.self) var session
    @State private var content: String = ""
    @State private var isEditing = false
    @State private var saveStatus: String?

    private let github = GitHubSync()

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 4)
            } else {
                ScrollView {
                    if content.isEmpty {
                        Text("No content available")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
        }
        .navigationTitle(transcript.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing { saveContent() }
                    isEditing.toggle()
                }
            }
            if isEditing {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Re-push to GitHub") { rePush() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let status = saveStatus {
                Text(status)
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
            }
        }
        .onAppear { loadContent() }
    }

    private func loadContent() {
        guard let url = transcript.fileURL else {
            content = "(File not available)"
            return
        }
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            content = "(Could not read file: \(error.localizedDescription))"
        }
    }

    private func saveContent() {
        guard let url = transcript.fileURL else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            showStatus("Saved")
        } catch {
            showStatus("Save failed")
        }
    }

    private func rePush() {
        guard let url = transcript.fileURL else { return }
        let filename = url.lastPathComponent
        Task {
            await github.configure(repo: session.settings.transcriptRepo, basePath: session.settings.transcriptRepoPath)
            do {
                try await github.push(
                    filename: filename,
                    content: content,
                    commitMessage: "update: \(transcript.title)"
                )
                showStatus("Pushed")
            } catch {
                showStatus("Push failed: \(error.localizedDescription)")
            }
        }
    }

    private func showStatus(_ text: String) {
        saveStatus = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            saveStatus = nil
        }
    }
}
