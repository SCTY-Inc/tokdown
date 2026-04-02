import SwiftUI

@main
struct TokDownMobileApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState.session)
                .environmentObject(appState.ble)
                .environmentObject(appState.transcription)
                .environmentObject(appState.calendar)
                .task {
                    await appState.requestPermissions()
                }
        }
    }
}

/// Holds all app-level dependencies. Avoids computed-property recreation issue.
@MainActor
final class AppState: ObservableObject {

    let ble = PendantBLE()
    let calendar = CalendarService()
    let transcription = TranscriptionService()
    let settings = SettingsStore()
    lazy var session: SessionManager = SessionManager(
        ble: ble,
        transcription: transcription,
        calendar: calendar,
        settings: settings
    )

    func requestPermissions() async {
        ble.startScanning()

        let speechAuthorized = await transcription.requestAuthorization()
        let calendarAuthorized = await calendar.requestAccess()

        var errors: [String] = []
        if !speechAuthorized {
            errors.append("Speech access denied")
        }
        if settings.recordingMode == .calendar && !calendarAuthorized {
            errors.append("Calendar access denied")
        }

        session.lastError = errors.isEmpty ? nil : errors.joined(separator: " • ")
        session.applySettings()
    }
}
