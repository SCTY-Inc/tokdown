import SwiftUI
import Observation

@main
struct TokDownApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState.session)
                .environment(appState.ble)
                .environment(appState.transcription)
                .environment(appState.calendar)
                .task {
                    appState.startServices()
                }
        }
    }
}

/// Holds all app-level dependencies. Avoids computed-property recreation issue.
@MainActor @Observable
final class AppState {

    let ble = PendantBLE()
    let calendar = CalendarService()
    let transcription = TranscriptionService()
    let metrics = MetricsCollector()
    let settings = SettingsStore()
    @ObservationIgnored lazy var session: SessionManager = SessionManager(
        ble: ble,
        transcription: transcription,
        calendar: calendar,
        settings: settings
    )

    func startServices() {
        ble.startScanning()
        transcription.refreshRecognitionSupport()
        session.applySettings()
        session.loadRecentTranscripts()
        session.pushQueue.drain()
    }
}
