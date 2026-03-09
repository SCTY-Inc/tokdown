import SwiftUI

@main
struct MenuBarRecorderApp: App {
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var coordinator: MenuBarCoordinator

    init() {
        let store = SettingsStore()
        _settingsStore = StateObject(wrappedValue: store)
        _coordinator = StateObject(wrappedValue: MenuBarCoordinator(settingsStore: store))
    }

    var body: some Scene {
        MenuBarExtra(coordinator.menuTitle, systemImage: coordinator.menuIconName) {
            MenuBarContentView()
                .environmentObject(coordinator)
                .environmentObject(settingsStore)
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            SettingsWindowView(settingsStore: settingsStore)
        }
    }
}
