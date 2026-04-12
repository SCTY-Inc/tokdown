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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("Recording", systemImage: "waveform")
                    .font(.headline)
                    .foregroundStyle(.red)

                Spacer()

                Text(formattedDuration)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.primary)
            }

            Text(session.transcriptionMode.title)
                .font(.caption.bold())
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.red.opacity(0.12), in: Capsule())

            if !session.currentTitle.isEmpty {
                Text(session.currentTitle)
                    .font(.headline)
            }

            transcriptStatusPanel

            Button(action: { session.stopRecording() }) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
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
            Text(session.processingStatusText)
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
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { session.startRecording() }) {
                Label("Record", systemImage: "waveform")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(ble.connectionState != .connected)

            Text(session.transcriptionMode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch session.transcriptionMode {
            case .live:
                Text("Live transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if livePreviewText.isEmpty {
                    Text("Listening for speech…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(livePreviewText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .lowPower:
                Text("Low Power capture")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("TokDown is saving pendant audio now and will transcribe after you stop.")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private var livePreviewText: String {
        transcription.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                ForEach(Array(calendar.upcomingMeetings.enumerated()), id: \.element.id) { index, meeting in
                    Button(action: { session.startRecording(meeting: meeting) }) {
                        upcomingMeetingRow(meeting)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(ble.connectionState != .connected)

                    if index < calendar.upcomingMeetings.count - 1 {
                        Divider().padding(.leading, 18)
                    }
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
                ForEach(Array(session.recentTranscripts.enumerated()), id: \.element.id) { index, transcript in
                    NavigationLink(destination: TranscriptDetailView(transcript: transcript)) {
                        recentTranscriptRow(transcript)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    if index < session.recentTranscripts.count - 1 {
                        Divider().padding(.leading, 24)
                    }
                }
            }
        }
    }

    private func upcomingMeetingRow(_ meeting: CalendarService.Meeting) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(meetingTime(meeting.startDate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func recentTranscriptRow(_ transcript: SessionManager.RecentTranscript) -> some View {
        HStack(spacing: 12) {
            Image(systemName: transcriptStatusIcon(transcript))
                .font(.system(size: 14))
                .foregroundStyle(transcriptStatusColor(transcript))

            VStack(alignment: .leading, spacing: 4) {
                Text(transcript.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(meetingTime(transcript.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    private func transcriptStatusIcon(_ transcript: SessionManager.RecentTranscript) -> String {
        switch transcript.syncStatus {
        case .localOnly:
            "checkmark.circle"
        case .queued:
            "clock"
        case .pushed:
            "checkmark.circle.fill"
        }
    }

    private func transcriptStatusColor(_ transcript: SessionManager.RecentTranscript) -> Color {
        switch transcript.syncStatus {
        case .localOnly:
            .secondary
        case .queued:
            .orange
        case .pushed:
            .green
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
            do {
                try await github.push(
                    filename: filename,
                    content: content,
                    commitMessage: "update: \(transcript.title)",
                    repo: session.settings.transcriptRepo,
                    basePath: session.settings.transcriptRepoPath
                )
                await MainActor.run {
                    session.markRecentTranscriptPushed(filename: filename)
                }
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
