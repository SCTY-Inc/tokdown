import Foundation
import EventKit
import Observation

/// EventKit integration for calendar-driven recording.
/// Fetches upcoming meetings, enables auto-start/stop based on event times.
@MainActor @Observable
final class CalendarService {

    struct Meeting: Identifiable, Sendable {
        let id = UUID()
        let eventIdentifier: String
        let title: String
        let startDate: Date
        let endDate: Date
        let calendarTitle: String
        let location: String?
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
                    location: event.location
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
