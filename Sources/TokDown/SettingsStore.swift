import Foundation
import Observation

/// UserDefaults-backed settings store.
@MainActor @Observable
final class SettingsStore {

    enum PushMode: String, CaseIterable, Sendable {
        case immediate
        case wifiOnly
        case chargingOnly
        case wifiOrCharging

        var title: String {
            switch self {
            case .immediate: "Immediate"
            case .wifiOnly: "Wi‑Fi Only"
            case .chargingOnly: "Charging Only"
            case .wifiOrCharging: "Wi‑Fi or Charging"
            }
        }

        var summary: String {
            switch self {
            case .immediate:
                "Push as soon as the transcript is ready."
            case .wifiOnly:
                "Wait for Wi‑Fi before pushing queued transcripts."
            case .chargingOnly:
                "Wait until the phone is charging before pushing."
            case .wifiOrCharging:
                "Push when on Wi‑Fi or while charging."
            }
        }
    }

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

    /// How transcription should run for new recordings.
    var transcriptionMode: SessionManager.TranscriptionMode {
        didSet { defaults.set(transcriptionMode.rawValue, forKey: "transcriptionMode") }
    }

    /// When queued transcripts are allowed to push to GitHub.
    var pushMode: PushMode {
        didSet { defaults.set(pushMode.rawValue, forKey: "pushMode") }
    }

    /// Target GitHub repo (owner/name)
    var transcriptRepo: String {
        didSet { defaults.set(transcriptRepo, forKey: "transcriptRepo") }
    }

    /// Path within the repo for transcripts
    var transcriptRepoPath: String {
        didSet { defaults.set(transcriptRepoPath, forKey: "transcriptRepoPath") }
    }

    /// Vocabulary hints for speech recognition (names, jargon, products)
    var vocabularyHints: [String] {
        didSet {
            defaults.set(vocabularyHints, forKey: "vocabularyHints")
        }
    }

    init() {
        self.hasGitHubPAT = defaults.bool(forKey: "hasGitHubPAT")
        self.autoPushEnabled = defaults.bool(forKey: "autoPushEnabled")
        self.transcriptRepo = defaults.string(forKey: "transcriptRepo") ?? ""
        self.transcriptRepoPath = defaults.string(forKey: "transcriptRepoPath") ?? "intel/transcripts"
        self.vocabularyHints = defaults.stringArray(forKey: "vocabularyHints") ?? []

        let modeRaw = defaults.string(forKey: "recordingMode") ?? "manual"
        self.recordingMode = SessionManager.RecordingMode(rawValue: modeRaw) ?? .manual

        let transcriptionModeRaw = defaults.string(forKey: "transcriptionMode") ?? SessionManager.TranscriptionMode.lowPower.rawValue
        self.transcriptionMode = SessionManager.TranscriptionMode(rawValue: transcriptionModeRaw) ?? .lowPower

        let pushModeRaw = defaults.string(forKey: "pushMode") ?? PushMode.immediate.rawValue
        self.pushMode = PushMode(rawValue: pushModeRaw) ?? .immediate
    }
}
