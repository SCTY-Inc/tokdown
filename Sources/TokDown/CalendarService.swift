import Foundation
@preconcurrency import EventKit

@MainActor
final class CalendarService: NSObject {
    enum CalendarReadAccessState: Equatable {
        case allowed
        case upgradeRequired
        case denied
    }

    struct UpcomingMeetingsLoadResult: Equatable {
        let meetings: [UpcomingMeeting]
        let accessState: CalendarReadAccessState
    }

    private let store = EKEventStore()
    nonisolated private static let meetingHorizon: TimeInterval = 7 * 24 * 60 * 60

    func upcomingMeetings(limit: Int) async -> UpcomingMeetingsLoadResult {
        let accessState = await requestReadAccess()
        guard accessState == .allowed else {
            return UpcomingMeetingsLoadResult(meetings: [], accessState: accessState)
        }

        let now = Date()
        let horizon = now.addingTimeInterval(Self.meetingHorizon)
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(UpcomingMeeting.init(event:))

        return UpcomingMeetingsLoadResult(
            meetings: Self.selectUpcomingMeetings(
                from: meetings,
                now: now,
                limit: limit,
                horizon: Self.meetingHorizon
            ),
            accessState: accessState
        )
    }

    private func requestReadAccess() async -> CalendarReadAccessState {
        let status = EKEventStore.authorizationStatus(for: .event)

        if let accessState = Self.readAccessState(for: status) {
            return accessState
        }

        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted ? .allowed : .denied)
            }
        }
    }

    nonisolated static func readAccessState(for status: EKAuthorizationStatus) -> CalendarReadAccessState? {
        switch status {
        case .fullAccess, .authorized:
            return .allowed
        case .writeOnly:
            return .upgradeRequired
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return nil
        @unknown default:
            return .denied
        }
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
