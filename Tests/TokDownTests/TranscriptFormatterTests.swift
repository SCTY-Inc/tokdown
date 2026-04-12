import Foundation
import Testing
@testable import TokDown

/// Unit tests for `TranscriptFormatter`.
///
/// These tests are pinned to a fixed TimeZone (UTC) so filename date parts
/// and ISO-8601 output are deterministic across machines and CI.
@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {

    // MARK: - Test helpers

    private static let utc = TimeZone(identifier: "UTC")!

    /// 2026-04-11T10:30:00Z
    private static let fixedStart = Date(timeIntervalSince1970: 1_775_903_400)
    /// 2026-04-11T11:00:00Z — 30 minutes after start
    private static let fixedEnd   = Date(timeIntervalSince1970: 1_775_905_200)

    private static func makeFormatter() -> TranscriptFormatter {
        TranscriptFormatter(timeZone: utc)
    }

    private static func line(_ text: String, at timestamp: TimeInterval) -> TranscriptionService.TranscriptLine {
        TranscriptionService.TranscriptLine(timestamp: timestamp, text: text)
    }

    private static func makeMeeting(
        title: String = "Standup",
        calendarTitle: String = "Work",
        eventID: String = "abc-123",
        location: String? = nil
    ) -> CalendarService.Meeting {
        CalendarService.Meeting(
            eventIdentifier: eventID,
            title: title,
            startDate: fixedStart,
            endDate: fixedEnd,
            calendarTitle: calendarTitle,
            location: location
        )
    }

    // MARK: - YAML front matter

    @Test("Manual recording (no meeting) emits pendant_ambient source")
    func manualRecordingSourceIsAmbient() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "Morning Notes",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "Hello world.",
            lines: []
        )

        #expect(doc.markdown.contains(#"source: "pendant_ambient""#))
        #expect(!doc.markdown.contains(#"source: "pendant_meeting""#))
        #expect(doc.markdown.contains(#"audio_source: "limitless_pendant""#))
    }

    @Test("Calendar-backed recording emits pendant_meeting source and calendar fields")
    func calendarBackedRecordingEmitsMeetingFields() throws {
        let meeting = Self.makeMeeting(
            title: "Standup",
            calendarTitle: "Work",
            eventID: "evt-42",
            location: "Room 3"
        )
        let doc = Self.makeFormatter().makeDocument(
            title: "Standup",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: meeting,
            fullText: "Planning sprint.",
            lines: []
        )

        #expect(doc.markdown.contains(#"source: "pendant_meeting""#))
        #expect(doc.markdown.contains(#"audio_source: "limitless_pendant""#))
        #expect(doc.markdown.contains(#"calendar: "Work""#))
        #expect(doc.markdown.contains(#"event_id: "evt-42""#))
        #expect(doc.markdown.contains(#"location: "Room 3""#))
        #expect(doc.markdown.contains("event_start:"))
        #expect(doc.markdown.contains("event_end:"))
    }

    @Test("Meeting without location omits the location YAML key")
    func meetingWithoutLocationOmitsKey() throws {
        let meeting = Self.makeMeeting(location: nil)
        let doc = Self.makeFormatter().makeDocument(
            title: "Standup",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: meeting,
            fullText: "",
            lines: []
        )

        #expect(!doc.markdown.contains("location:"))
    }

    @Test("Front matter starts with --- and contains recording timestamps")
    func frontMatterDelimitedAndHasTimestamps() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "Test",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "Body",
            lines: []
        )

        #expect(doc.markdown.hasPrefix("---\n"))
        #expect(doc.markdown.contains("recording_started_at: \"2026-04-11T10:30:00Z\""))
        #expect(doc.markdown.contains("recording_ended_at: \"2026-04-11T11:00:00Z\""))
    }

    // MARK: - Timestamp chunking (5-second windows)

    @Test("Lines within 5-second window collapse into one timestamped chunk")
    func linesWithinWindowCollapse() throws {
        let lines = [
            Self.line("Hello", at: 0),
            Self.line("world", at: 2),
            Self.line("again", at: 4)
        ]
        let doc = Self.makeFormatter().makeDocument(
            title: "Test",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "Hello world again",
            lines: lines
        )

        #expect(doc.markdown.contains("[00:00] Hello world again"))
    }

    @Test("Lines spanning >5-second gap split into separate chunks")
    func linesAcrossGapSplit() throws {
        let lines = [
            Self.line("First", at: 0),
            Self.line("Second", at: 10),
            Self.line("Third", at: 20)
        ]
        let doc = Self.makeFormatter().makeDocument(
            title: "Test",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "",
            lines: lines
        )

        #expect(doc.markdown.contains("[00:00] First"))
        #expect(doc.markdown.contains("[00:10] Second"))
        #expect(doc.markdown.contains("[00:20] Third"))
    }

    @Test("Timestamps past one hour use h:mm:ss format")
    func longTimestampsUseHourFormat() throws {
        let lines = [Self.line("Deep work", at: 3725)] // 1h 02m 05s
        let doc = Self.makeFormatter().makeDocument(
            title: "Long",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "",
            lines: lines
        )

        #expect(doc.markdown.contains("[1:02:05] Deep work"))
    }

    // MARK: - Title handling and filename

    @Test("Empty title falls back to 'Pendant Recording'")
    func emptyTitleFallsBack() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "Some audio",
            lines: []
        )

        #expect(doc.title == "Pendant Recording")
        #expect(doc.markdown.contains("# Pendant Recording"))
        #expect(doc.filename.hasSuffix("_Pendant-Recording.md"))
    }

    @Test("Filename uses YYYY-MM-DD_HH-mm prefix in the formatter's time zone")
    func filenameHasDatePrefix() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "Quick Note",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "",
            lines: []
        )

        // 2026-04-11T10:30:00Z → "2026-04-11_10-30" in UTC
        #expect(doc.filename == "2026-04-11_10-30_Quick-Note.md")
    }

    @Test("Very long title truncates to 60 characters in filename only")
    func longTitleTruncatesFilename() throws {
        let longTitle = String(repeating: "A", count: 120)
        let doc = Self.makeFormatter().makeDocument(
            title: longTitle,
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "",
            lines: []
        )

        // Filename portion between last "_" and ".md"
        let namePart = doc.filename
            .replacingOccurrences(of: "2026-04-11_10-30_", with: "")
            .replacingOccurrences(of: ".md", with: "")
        #expect(namePart.count == 60)
        // Full title still present in body heading (no truncation there)
        #expect(doc.markdown.contains("# \(longTitle)"))
    }

    @Test("Non-ASCII characters stripped from filename, preserved in body")
    func nonASCIIHandling() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "Café résumé 日本語",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "",
            lines: []
        )

        // Filename regex `[^a-zA-Z0-9 ]` strips non-ASCII letters.
        #expect(!doc.filename.contains("é"))
        #expect(!doc.filename.contains("日"))
        // But the body heading and YAML title keep the original characters.
        #expect(doc.markdown.contains("# Café résumé 日本語"))
        #expect(doc.markdown.contains("title: \"Café résumé 日本語\""))
    }

    // MARK: - Body edge cases

    @Test("Empty transcript with no lines emits '(No transcript)' placeholder")
    func emptyTranscriptPlaceholder() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "Empty",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "",
            lines: []
        )

        #expect(doc.markdown.contains("(No transcript)"))
    }

    @Test("fullText is used verbatim when no timestamped lines are supplied")
    func fullTextFallback() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "Plain",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "   Just some free-form text.\n",
            lines: []
        )

        #expect(doc.markdown.contains("Just some free-form text."))
        #expect(!doc.markdown.contains("(No transcript)"))
    }

    @Test("Whitespace-only timestamped lines fall back to fullText instead of emitting an empty [00:00] row")
    func whitespaceOnlyLinesFallBackToFullText() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: "Plain",
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "Recovered transcript",
            lines: [Self.line("   ", at: 0)]
        )

        #expect(doc.markdown.contains("Recovered transcript"))
        #expect(!doc.markdown.contains("[00:00]"))
    }

    @Test("YAML double quotes in title are escaped")
    func yamlEscapesQuotes() throws {
        let doc = Self.makeFormatter().makeDocument(
            title: #"She said "hello""#,
            startTime: Self.fixedStart,
            endTime: Self.fixedEnd,
            meeting: nil,
            fullText: "",
            lines: []
        )

        // YAML front matter should contain escaped quotes: \"
        #expect(doc.markdown.contains(#"title: "She said \"hello\"""#))
    }
}
