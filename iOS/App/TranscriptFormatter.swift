import Foundation

/// Formats transcript data into YAML front matter + timestamped markdown body.
/// Output format follows the TokDown transcript contract, with pendant-specific
/// audio source metadata.
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

    // MARK: - Front matter

    /// Build YAML front matter block.
    private func makeFrontMatter(
        title: String,
        startTime: Date,
        endTime: Date,
        meeting: CalendarService.Meeting?
    ) -> String {
        var yamlLines: [String?] = [
            "---",
            yamlScalar(key: "title", value: title),
            yamlScalar(key: "source", value: meeting == nil ? "manual_recording" : "calendar_selection"),
            yamlScalar(key: "calendar_provider", value: meeting == nil ? nil : "apple_calendar"),
            yamlScalar(key: "audio_source", value: "limitless_pendant"),
            yamlScalar(key: "recording_started_at", value: iso8601(startTime)),
            yamlScalar(key: "recording_ended_at", value: iso8601(endTime))
        ]

        if let meeting {
            yamlLines.append(yamlScalar(key: "calendar", value: meeting.calendarTitle))
            yamlLines.append(yamlScalar(key: "event_id", value: meeting.eventIdentifier))
            yamlLines.append(yamlScalar(key: "event_start", value: iso8601(meeting.startDate)))
            yamlLines.append(yamlScalar(key: "event_end", value: iso8601(meeting.endDate)))
            yamlLines.append(yamlScalar(key: "location", value: meeting.location))
            yamlLines.append(yamlScalar(key: "url", value: meeting.url?.absoluteString))
            yamlLines.append(yamlPerson(key: "organizer", person: meeting.organizer))
            yamlLines.append(yamlPeople(key: "attendees", people: meeting.attendees))
            yamlLines.append(yamlBlock(key: "notes", value: meeting.notes))
        }

        yamlLines.append("---")
        return yamlLines.compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: - Body

    /// Collapse transcript lines into timestamped paragraphs (5-second grouping).
    private func makeBody(
        fullText: String,
        lines: [TranscriptionService.TranscriptLine]
    ) -> String {
        let filteredLines = lines.compactMap { line -> TranscriptionService.TranscriptLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptionService.TranscriptLine(timestamp: line.timestamp, text: text)
        }

        if filteredLines.isEmpty {
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(No transcript)" : trimmed
        }

        var result: [String] = []
        var currentChunk: [String] = []
        var chunkStart = filteredLines[0].timestamp

        for line in filteredLines {
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

    /// Generate date-first filename: YYYY-MM-DD_HH-mm-ss-SSS_Title.md
    private func makeFilename(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"

        let datePart = formatter.string(from: date)
        let safeName = title
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: "-", options: .regularExpression)
            .prefix(60)
        let filenameTitle = safeName.isEmpty ? "Pendant-Recording" : String(safeName)
        return "\(datePart)_\(filenameTitle).md"
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

    private func yamlScalar(key: String, value: String?) -> String? {
        guard let value = trimmedOrNil(value) else { return nil }
        return "\(key): \"\(escapeYAML(value))\""
    }

    private func yamlBlock(key: String, value: String?) -> String? {
        guard let value = trimmedOrNil(value) else { return nil }
        let indented = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
        return "\(key): |\n\(indented)"
    }

    private func yamlPerson(key: String, person: CalendarService.MeetingPerson?) -> String? {
        guard let person, !person.isEmpty else { return nil }

        var lines = ["\(key):"]
        if let name = trimmedOrNil(person.name) {
            lines.append("  name: \"\(escapeYAML(name))\"")
        }
        if let email = trimmedOrNil(person.email) {
            lines.append("  email: \"\(escapeYAML(email))\"")
        }
        return lines.joined(separator: "\n")
    }

    private func yamlPeople(key: String, people: [CalendarService.MeetingPerson]) -> String? {
        let validPeople = people.filter { !$0.isEmpty }
        guard !validPeople.isEmpty else { return nil }

        var lines = ["\(key):"]
        for person in validPeople {
            if let name = trimmedOrNil(person.name), let email = trimmedOrNil(person.email) {
                lines.append("  - name: \"\(escapeYAML(name))\"")
                lines.append("    email: \"\(escapeYAML(email))\"")
            } else if let name = trimmedOrNil(person.name) {
                lines.append("  - name: \"\(escapeYAML(name))\"")
            } else if let email = trimmedOrNil(person.email) {
                lines.append("  - email: \"\(escapeYAML(email))\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
