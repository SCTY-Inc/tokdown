import SwiftUI
import AppKit

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var windowController: NSWindowController?

    func show(settingsStore: SettingsStore) {
        let windowSize = NSSize(width: 380, height: 220)

        if windowController == nil {
            let hostingController = NSHostingController(rootView: SettingsWindowView(settingsStore: settingsStore))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(windowSize)
            window.minSize = windowSize
            window.maxSize = windowSize
            window.isReleasedWhenClosed = false
            windowController = NSWindowController(window: window)
        }

        windowController?.window?.setContentSize(windowSize)
        windowController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }
}

private struct MenuBarLabelView: View {
    let state: RecordingState
    let menuTitle: String

    var body: some View {
        HStack(spacing: 6) {
            MenuBarIconView(state: state)
            if !menuTitle.isEmpty {
                Text(menuTitle)
            }
        }
    }
}

@main
struct TokDownApp: App {
    @State private var settingsStore: SettingsStore
    @State private var coordinator: MenuBarCoordinator

    init() {
        let store = SettingsStore()
        _settingsStore = State(wrappedValue: store)
        _coordinator = State(wrappedValue: MenuBarCoordinator(settingsStore: store))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(coordinator)
                .environment(settingsStore)
        } label: {
            MenuBarLabelView(
                state: coordinator.state,
                menuTitle: coordinator.menuTitle
            )
        }
        .menuBarExtraStyle(.menu)
    }
}
