import Foundation
import EventKit

enum RecordingState {
    case idle
    case recording
    case transcribing
}

enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio"
        }
    }
}

struct AppSettings: Codable {
    var saveFolderPath: String
    var audioSource: AudioSource

    init(saveFolderPath: String, audioSource: AudioSource = .systemAudio) {
        self.saveFolderPath = saveFolderPath
        self.audioSource = audioSource
    }
}

struct UpcomingMeeting: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date

    init(event: EKEvent) {
        id = event.eventIdentifier ?? UUID().uuidString
        title = event.title
        startDate = event.startDate
        endDate = event.endDate
    }

    var timeWindowLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }
}

struct TranscriptLine {
    let timestamp: TimeInterval
    let text: String
}
