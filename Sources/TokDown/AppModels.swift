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

    var metadataValue: String {
        switch self {
        case .microphone: "microphone"
        case .systemAudio: "system_audio"
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

struct MeetingPerson: Hashable {
    let name: String?
    let email: String?

    var isEmpty: Bool {
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedName.isEmpty && normalizedEmail.isEmpty
    }

    init(name: String? = nil, email: String? = nil) {
        self.name = name?.nilIfBlank
        self.email = email?.nilIfBlank
    }

    init(participant: EKParticipant) {
        self.init(
            name: participant.name,
            email: Self.emailAddress(from: participant.url)
        )
    }

    private static func emailAddress(from url: URL?) -> String? {
        guard let url else { return nil }

        if url.scheme?.lowercased() == "mailto" {
            let prefix = "mailto:"
            let absoluteString = url.absoluteString
            guard absoluteString.lowercased().hasPrefix(prefix) else { return nil }
            return String(absoluteString.dropFirst(prefix.count)).removingPercentEncoding?.nilIfBlank
        }

        return nil
    }
}

struct UpcomingMeeting: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String?
    let location: String?
    let notes: String?
    let url: URL?
    let organizer: MeetingPerson?
    let attendees: [MeetingPerson]

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarTitle: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        organizer: MeetingPerson? = nil,
        attendees: [MeetingPerson] = []
    ) {
        self.id = id
        self.title = title.nilIfBlank ?? "Untitled Meeting"
        self.startDate = startDate
        self.endDate = endDate
        self.calendarTitle = calendarTitle?.nilIfBlank
        self.location = location?.nilIfBlank
        self.notes = notes?.nilIfBlank
        self.url = url
        self.organizer = organizer?.isEmpty == true ? nil : organizer
        self.attendees = attendees.filter { !$0.isEmpty }
    }

    init(event: EKEvent) {
        self.init(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            calendarTitle: event.calendar.title,
            location: event.location,
            notes: event.notes,
            url: event.url,
            organizer: event.organizer.map(MeetingPerson.init(participant:)),
            attendees: (event.attendees ?? []).map(MeetingPerson.init(participant:))
        )
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
