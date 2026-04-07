import Foundation
@preconcurrency import EventKit

@MainActor
final class CalendarService: NSObject {
    private let store = EKEventStore()
    nonisolated private static let meetingHorizon: TimeInterval = 7 * 24 * 60 * 60

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
        let horizon = now.addingTimeInterval(Self.meetingHorizon)
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(UpcomingMeeting.init(event:))

        return Self.selectUpcomingMeetings(
            from: meetings,
            now: now,
            limit: limit,
            horizon: Self.meetingHorizon
        )
    }

    nonisolated static func selectUpcomingMeetings(
        from meetings: [UpcomingMeeting],
        now: Date,
        limit: Int,
        horizon: TimeInterval = meetingHorizon
    ) -> [UpcomingMeeting] {
        let end = now.addingTimeInterval(horizon)

        return meetings
            .filter { $0.endDate > now }
            .filter { $0.startDate <= end }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.endDate < rhs.endDate
                }
                return lhs.startDate < rhs.startDate
            }
            .prefix(limit)
            .map { $0 }
    }
}
