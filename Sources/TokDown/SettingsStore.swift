import Foundation
import Observation

/// UserDefaults-backed settings store.
@MainActor @Observable
final class SettingsStore {

    private let defaults = UserDefaults.standard

    /// Whether GitHub PAT has been configured (actual token is in Keychain)
    var hasGitHubPAT: Bool {
        didSet { defaults.set(hasGitHubPAT, forKey: "hasGitHubPAT") }
    }

    /// Default recording mode
    var recordingMode: SessionManager.RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: "recordingMode") }
    }

    /// Auto-push transcripts to GitHub after recording
    var autoPushEnabled: Bool {
        didSet { defaults.set(autoPushEnabled, forKey: "autoPushEnabled") }
    }

    /// Target repo path for transcripts
    let transcriptRepoPath = "intel/transcripts"

    /// Vocabulary hints for speech recognition (names, jargon, products)
    var vocabularyHints: [String] {
        didSet {
            defaults.set(vocabularyHints, forKey: "vocabularyHints")
        }
    }

    init() {
        self.hasGitHubPAT = defaults.bool(forKey: "hasGitHubPAT")
        self.autoPushEnabled = defaults.bool(forKey: "autoPushEnabled")
        self.vocabularyHints = defaults.stringArray(forKey: "vocabularyHints") ?? []

        let modeRaw = defaults.string(forKey: "recordingMode") ?? "manual"
        self.recordingMode = SessionManager.RecordingMode(rawValue: modeRaw) ?? .manual
    }
}
