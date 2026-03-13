import XCTest
@testable import TokDown

final class CalendarServiceTests: XCTestCase {
    func testSelectUpcomingMeetingsPicksNextThreeAcrossWiderWindow() {
        let now = date("2026-03-13T00:15:00Z")
        let meetings = [
            meeting(title: "Already Over", start: "2026-03-12T22:00:00Z", end: "2026-03-12T23:00:00Z"),
            meeting(title: "Morning Sync", start: "2026-03-13T13:00:00Z", end: "2026-03-13T13:30:00Z"),
            meeting(title: "Afternoon Review", start: "2026-03-13T18:00:00Z", end: "2026-03-13T18:30:00Z"),
            meeting(title: "Tomorrow Planning", start: "2026-03-14T15:00:00Z", end: "2026-03-14T16:00:00Z"),
            meeting(title: "Next Week", start: "2026-03-20T15:00:00Z", end: "2026-03-20T16:00:00Z")
        ]

        let selected = CalendarService.selectUpcomingMeetings(
            from: meetings,
            now: now,
            limit: 3,
            horizon: 7 * 24 * 60 * 60
        )

        XCTAssertEqual(selected.map(\.title), [
            "Morning Sync",
            "Afternoon Review",
            "Tomorrow Planning"
        ])
    }

    private func meeting(title: String, start: String, end: String) -> UpcomingMeeting {
        UpcomingMeeting(
            id: title,
            title: title,
            startDate: date(start),
            endDate: date(end)
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
