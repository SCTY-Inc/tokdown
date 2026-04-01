import SwiftUI

@main
struct TokDownMobileApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState.session)
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
        _ = await transcription.requestAuthorization()
        _ = await calendar.requestAccess()
    }
}
