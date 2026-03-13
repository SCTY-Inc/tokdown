import XCTest
@testable import TokDown

final class TranscriptFormatterTests: XCTestCase {
    func testCalendarSelectionAddsFrontMatter() {
        let formatter = TranscriptFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        let start = date("2026-03-13T14:00:00Z")
        let end = date("2026-03-13T14:30:00Z")
        let meeting = UpcomingMeeting(
            id: "event-123",
            title: "Weekly Product Sync",
            startDate: start,
            endDate: end,
            calendarTitle: "Work",
            location: "Zoom",
            notes: "Agenda line 1\nAgenda line 2",
            url: URL(string: "https://zoom.us/j/123"),
            organizer: MeetingPerson(name: "Jane Doe", email: "jane@example.com"),
            attendees: [
                MeetingPerson(name: "Jane Doe", email: "jane@example.com"),
                MeetingPerson(name: "Alex Smith", email: "alex@example.com")
            ]
        )

        let document = formatter.makeDocument(
            fallbackTitle: meeting.title,
            startTime: start,
            endTime: end,
            audioSource: .systemAudio,
            meeting: meeting,
            fullText: "Intro roadmap blockers next steps",
            lines: [
                TranscriptLine(timestamp: 0, text: "Intro roadmap"),
                TranscriptLine(timestamp: 6, text: "Blockers next steps")
            ]
        )

        XCTAssertEqual(document.title, "Weekly Product Sync")
        XCTAssertEqual(document.markdown, """
---
title: \"Weekly Product Sync\"
source: \"calendar_selection\"
calendar_provider: \"apple_calendar\"
audio_source: \"system_audio\"
recording_started_at: \"2026-03-13T14:00:00Z\"
recording_ended_at: \"2026-03-13T14:30:00Z\"
calendar: \"Work\"
event_id: \"event-123\"
event_start: \"2026-03-13T14:00:00Z\"
event_end: \"2026-03-13T14:30:00Z\"
location: \"Zoom\"
url: \"https://zoom.us/j/123\"
organizer:
  name: \"Jane Doe\"
  email: \"jane@example.com\"
attendees:
  - name: \"Jane Doe\"
    email: \"jane@example.com\"
  - name: \"Alex Smith\"
    email: \"alex@example.com\"
notes: |
  Agenda line 1
  Agenda line 2
---

# Weekly Product Sync

2026-03-13 14:00–14:30

[00:00] Intro roadmap

[00:06] Blockers next steps
""")
    }

    func testManualRecordingUsesTranscriptTextForTitle() {
        let formatter = TranscriptFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        let start = date("2026-03-13T16:00:00Z")
        let end = date("2026-03-13T16:12:00Z")

        let document = formatter.makeDocument(
            fallbackTitle: "Recording",
            startTime: start,
            endTime: end,
            audioSource: .systemAudio,
            meeting: nil,
            fullText: "Quarterly planning kickoff and budget review with hiring updates.",
            lines: []
        )

        XCTAssertEqual(document.title, "Quarterly planning kickoff and budget review with hiring updates")
        XCTAssertEqual(document.markdown, """
---
title: \"Quarterly planning kickoff and budget review with hiring updates\"
source: \"manual_recording\"
audio_source: \"system_audio\"
recording_started_at: \"2026-03-13T16:00:00Z\"
recording_ended_at: \"2026-03-13T16:12:00Z\"
---

# Quarterly planning kickoff and budget review with hiring updates

2026-03-13 16:00–16:12

Quarterly planning kickoff and budget review with hiring updates.
""")
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
