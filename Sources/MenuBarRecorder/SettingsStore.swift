import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings

    private let defaults = UserDefaults.standard
    private let settingsKey = "MenuBarRecorder.Settings.V2"

    init() {
        settings = Self.defaultSettings
        load()
    }

    static var defaultSettings: AppSettings {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let defaultFolder = docs.appendingPathComponent("Transcripts", isDirectory: true)
        return AppSettings(saveFolderPath: defaultFolder.path)
    }

    var saveFolderURL: URL {
        URL(fileURLWithPath: settings.saveFolderPath, isDirectory: true)
    }

    func setSaveFolder(_ url: URL) {
        settings.saveFolderPath = url.standardizedFileURL.path
        save()
    }

    func setAudioSource(_ source: AudioSource) {
        settings.audioSource = source
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.setValue(data, forKey: settingsKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: settingsKey),
           let restored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = restored
        }
    }
}
