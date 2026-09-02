import Foundation
import EventKit
import Observation

/// EventKit integration for calendar-driven recording.
/// Fetches upcoming meetings, enables auto-start/stop based on event times.
@MainActor @Observable
final class CalendarService {

    struct MeetingPerson: Hashable, Sendable {
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

    struct Meeting: Identifiable, Sendable {
        let eventIdentifier: String
        var id: String { eventIdentifier }
        let title: String
        let startDate: Date
        let endDate: Date
        let calendarTitle: String
        let location: String?
        let participantNames: [String]
        let notes: String?
        let url: URL?
        let organizer: MeetingPerson?
        let attendees: [MeetingPerson]

        init(
            eventIdentifier: String,
            title: String,
            startDate: Date,
            endDate: Date,
            calendarTitle: String,
            location: String? = nil,
            participantNames: [String] = [],
            notes: String? = nil,
            url: URL? = nil,
            organizer: MeetingPerson? = nil,
            attendees: [MeetingPerson] = []
        ) {
            self.eventIdentifier = eventIdentifier
            self.title = title.nilIfBlank ?? "Untitled"
            self.startDate = startDate
            self.endDate = endDate
            self.calendarTitle = calendarTitle
            self.location = location?.nilIfBlank
            self.notes = notes?.nilIfBlank
            self.url = url
            self.organizer = organizer?.isEmpty == true ? nil : organizer
            self.attendees = attendees.filter { !$0.isEmpty }

            let names = participantNames.isEmpty
                ? self.attendees.compactMap(\.name)
                : participantNames
            self.participantNames = names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    var upcomingMeetings: [Meeting] = []
    var isAuthorized = false

    private let eventStore = EKEventStore()
    private var refreshTimer: Timer?

    /// Request calendar access.
    /// - Returns: true if full access granted
    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            isAuthorized = granted
            if granted {
                refreshMeetings()
                startRefreshTimer()
            }
            return granted
        } catch {
            isAuthorized = false
            return false
        }
    }

    /// Fetch meetings for the next N hours.
    /// - Parameter hours: Lookahead window (default 24)
    /// - Returns: Array of upcoming non-all-day meetings sorted by start time
    func fetchUpcoming(hours: Int = 24) -> [Meeting] {
        let now = Date()
        guard let endDate = Calendar.current.date(byAdding: .hour, value: hours, to: now) else {
            return []
        }

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)
        return events
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                Meeting(
                    eventIdentifier: event.eventIdentifier,
                    title: event.title ?? "Untitled",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    calendarTitle: event.calendar?.title ?? "",
                    location: event.location,
                    participantNames: event.attendees?
                        .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty } ?? [],
                    notes: event.notes,
                    url: event.url,
                    organizer: event.organizer.map(MeetingPerson.init(participant:)),
                    attendees: (event.attendees ?? []).map(MeetingPerson.init(participant:))
                )
            }
    }

    /// Find the current meeting (now falls within start..end).
    func currentMeeting() -> Meeting? {
        let now = Date()
        return upcomingMeetings.first { meeting in
            now >= meeting.startDate && now <= meeting.endDate
        }
    }

    /// Refresh the upcoming meetings list.
    func refreshMeetings() {
        upcomingMeetings = fetchUpcoming()
    }

    // MARK: - Private

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMeetings()
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
