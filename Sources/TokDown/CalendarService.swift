import Foundation
@preconcurrency import EventKit

@MainActor
final class CalendarService: NSObject {
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)

        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func upcomingMeetings(limit: Int) async -> [UpcomingMeeting] {
        guard await requestAccess() else { return [] }

        let now = Date()
        let horizon = Calendar.current.date(byAdding: .hour, value: 12, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let events = store.events(matching: predicate)

        return events
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map(UpcomingMeeting.init(event:))
    }

    func meetingAtCurrentTime() async -> UpcomingMeeting? {
        guard await requestAccess() else { return nil }

        let now = Date()
        let start = now.addingTimeInterval(-900)
        let end = now.addingTimeInterval(900)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        let active = events.first {
            $0.startDate <= now && $0.endDate >= now
        }

        if let active = active {
            return UpcomingMeeting(event: active)
        }

        return nil
    }
}
