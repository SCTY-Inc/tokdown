import Foundation

@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings

    private let defaults: UserDefaults
    private let settingsKey = "TokDown.Settings.V2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
