import Foundation
import SwiftUI

/// UserDefaults-backed settings store.
@MainActor
final class SettingsStore: ObservableObject {

    private let defaults = UserDefaults.standard

    /// Whether GitHub PAT has been configured (actual token is in Keychain)
    @Published var hasGitHubPAT: Bool {
        didSet { defaults.set(hasGitHubPAT, forKey: "hasGitHubPAT") }
    }

    /// Default recording mode
    @Published var recordingMode: SessionManager.RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: "recordingMode") }
    }

    /// Auto-push transcripts to GitHub after recording
    @Published var autoPushEnabled: Bool {
        didSet { defaults.set(autoPushEnabled, forKey: "autoPushEnabled") }
    }

    /// Target repo path for transcripts
    let transcriptRepoPath = "intel/transcripts"

    init() {
        self.hasGitHubPAT = defaults.bool(forKey: "hasGitHubPAT")
        self.autoPushEnabled = defaults.bool(forKey: "autoPushEnabled")

        let modeRaw = defaults.string(forKey: "recordingMode") ?? "manual"
        self.recordingMode = SessionManager.RecordingMode(rawValue: modeRaw) ?? .manual
    }
}
