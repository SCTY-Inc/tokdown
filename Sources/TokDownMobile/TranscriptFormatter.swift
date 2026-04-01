import Foundation

/// Formats transcript data into YAML front matter + timestamped markdown body.
/// Output format matches TokDown exactly, with pendant-specific source metadata.
struct TranscriptFormatter {

    struct TranscriptDocument {
        let title: String
        let filename: String
        let markdown: String
    }

    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// Build a complete markdown transcript document.
    /// - Parameters:
    ///   - title: Meeting or inferred title
    ///   - startTime: Recording start
    ///   - endTime: Recording end
    ///   - meeting: Associated calendar event, if any
    ///   - fullText: Complete transcript text
    ///   - lines: Timestamped transcript segments
    /// - Returns: TranscriptDocument with title, filename, and markdown content
    func makeDocument(
        title: String,
        startTime: Date,
        endTime: Date,
        meeting: CalendarService.Meeting?,
        fullText: String,
        lines: [TranscriptionService.TranscriptLine]
    ) -> TranscriptDocument {
        let resolvedTitle = title.isEmpty ? "Pendant Recording" : title
        let filename = makeFilename(title: resolvedTitle, date: startTime)
        let frontMatter = makeFrontMatter(
            title: resolvedTitle,
            startTime: startTime,
            endTime: endTime,
            meeting: meeting
        )
        let body = makeBody(fullText: fullText, lines: lines)

        let markdown = """
        \(frontMatter)

        # \(resolvedTitle)

        \(headingDateRange(startTime: startTime, endTime: endTime))

        \(body)
        """.replacingOccurrences(of: "        ", with: "")

        return TranscriptDocument(title: resolvedTitle, filename: filename, markdown: markdown)
    }

    // MARK: - Front matter (matches TokDown format)

    /// Build YAML front matter block.
    /// Keys: title, source, audio_source, recording_started_at, recording_ended_at,
    ///        plus calendar fields when meeting is present.
    private func makeFrontMatter(
        title: String,
        startTime: Date,
        endTime: Date,
        meeting: CalendarService.Meeting?
    ) -> String {
        // source: "pendant_meeting" when calendar-linked, "pendant_ambient" otherwise
        // audio_source: "limitless_pendant"
        //
        // ---
        // title: "Meeting Title"
        // source: "pendant_ambient"
        // audio_source: "limitless_pendant"
        // recording_started_at: "2026-04-01T10:00:00-07:00"
        // recording_ended_at: "2026-04-01T10:30:00-07:00"
        // calendar: "Work"
        // event_id: "abc123"
        // event_start: "2026-04-01T10:00:00-07:00"
        // event_end: "2026-04-01T10:30:00-07:00"
        // ---
        var yamlLines: [String] = [
            "---",
            "title: \"\(escapeYAML(title))\"",
            "source: \"\(meeting != nil ? "pendant_meeting" : "pendant_ambient")\"",
            "audio_source: \"limitless_pendant\"",
            "recording_started_at: \"\(iso8601(startTime))\"",
            "recording_ended_at: \"\(iso8601(endTime))\""
        ]

        if let meeting {
            yamlLines.append("calendar: \"\(escapeYAML(meeting.calendarTitle))\"")
            yamlLines.append("event_id: \"\(escapeYAML(meeting.eventIdentifier))\"")
            yamlLines.append("event_start: \"\(iso8601(meeting.startDate))\"")
            yamlLines.append("event_end: \"\(iso8601(meeting.endDate))\"")
            if let location = meeting.location {
                yamlLines.append("location: \"\(escapeYAML(location))\"")
            }
        }

        yamlLines.append("---")
        return yamlLines.joined(separator: "\n")
    }

    // MARK: - Body

    /// Collapse transcript lines into timestamped paragraphs (5-second grouping).
    private func makeBody(
        fullText: String,
        lines: [TranscriptionService.TranscriptLine]
    ) -> String {
        if lines.isEmpty {
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(No transcript)" : trimmed
        }

        var result: [String] = []
        var currentChunk: [String] = []
        var chunkStart = lines[0].timestamp

        for line in lines {
            if line.timestamp - chunkStart > 5, !currentChunk.isEmpty {
                result.append("[\(formatTimestamp(chunkStart))] \(currentChunk.joined(separator: " "))")
                currentChunk = []
                chunkStart = line.timestamp
            }
            currentChunk.append(line.text)
        }

        if !currentChunk.isEmpty {
            result.append("[\(formatTimestamp(chunkStart))] \(currentChunk.joined(separator: " "))")
        }

        return result.joined(separator: "\n\n")
    }

    // MARK: - Filename

    /// Generate date-first filename: YYYY-MM-DD_HH-mm_Title.md
    private func makeFilename(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"

        let datePart = formatter.string(from: date)
        let safeName = title
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: "-", options: .regularExpression)
            .prefix(60)
        return "\(datePart)_\(safeName).md"
    }

    // MARK: - Helpers

    private func headingDateRange(startTime: Date, endTime: Date) -> String {
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.timeZone = timeZone
        dateFmt.dateFormat = "yyyy-MM-dd"

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = timeZone
        timeFmt.dateFormat = "HH:mm"

        return "\(dateFmt.string(from: startTime)) \(timeFmt.string(from: startTime))\u{2013}\(timeFmt.string(from: endTime))"
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func escapeYAML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
