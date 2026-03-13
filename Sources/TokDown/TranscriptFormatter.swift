import Foundation

struct TranscriptDocument {
    let title: String
    let markdown: String
}

struct TranscriptFormatter {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func makeDocument(
        fallbackTitle: String?,
        startTime: Date,
        endTime: Date,
        audioSource: AudioSource,
        meeting: UpcomingMeeting?,
        fullText: String,
        lines: [TranscriptLine]
    ) -> TranscriptDocument {
        let title = resolveTitle(
            fallbackTitle: fallbackTitle,
            meeting: meeting,
            audioSource: audioSource,
            fullText: fullText
        )
        let body = makeBody(fullText: fullText, lines: lines)
        let markdown = """
        \(makeFrontMatter(
            title: title,
            startTime: startTime,
            endTime: endTime,
            audioSource: audioSource,
            meeting: meeting
        ))

        # \(title)

        \(headingDateRange(startTime: startTime, endTime: endTime))

        \(body)
        """.replacingOccurrences(of: "        ", with: "")

        return TranscriptDocument(title: title, markdown: markdown)
    }

    private func resolveTitle(
        fallbackTitle: String?,
        meeting: UpcomingMeeting?,
        audioSource: AudioSource,
        fullText: String
    ) -> String {
        if let meeting, !meeting.title.isEmpty {
            return meeting.title
        }

        if let inferredTitle = inferredTitle(from: fullText) {
            return inferredTitle
        }

        if let fallbackTitle,
           let trimmedFallback = trimmedOrNil(fallbackTitle),
           trimmedFallback.lowercased() != "recording" {
            return trimmedFallback
        }

        return audioSource.title
    }

    private func makeFrontMatter(
        title: String,
        startTime: Date,
        endTime: Date,
        audioSource: AudioSource,
        meeting: UpcomingMeeting?
    ) -> String {
        var lines: [String?] = [
            "---",
            yamlScalar(key: "title", value: title),
            yamlScalar(key: "source", value: meeting == nil ? "manual_recording" : "calendar_selection"),
            yamlScalar(key: "calendar_provider", value: meeting == nil ? nil : "apple_calendar"),
            yamlScalar(key: "audio_source", value: audioSource.metadataValue),
            yamlScalar(key: "recording_started_at", value: iso8601String(from: startTime)),
            yamlScalar(key: "recording_ended_at", value: iso8601String(from: endTime))
        ]

        if let meeting {
            lines.append(yamlScalar(key: "calendar", value: meeting.calendarTitle))
            lines.append(yamlScalar(key: "event_id", value: meeting.id))
            lines.append(yamlScalar(key: "event_start", value: iso8601String(from: meeting.startDate)))
            lines.append(yamlScalar(key: "event_end", value: iso8601String(from: meeting.endDate)))
            lines.append(yamlScalar(key: "location", value: meeting.location))
            lines.append(yamlScalar(key: "url", value: meeting.url?.absoluteString))
            lines.append(yamlPerson(key: "organizer", person: meeting.organizer))
            lines.append(yamlPeople(key: "attendees", people: meeting.attendees))
            lines.append(yamlBlock(key: "notes", value: meeting.notes))
        }

        lines.append("---")
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    private func makeBody(fullText: String, lines: [TranscriptLine]) -> String {
        if lines.isEmpty {
            return trimmedOrNil(fullText) ?? "(No transcript)"
        }

        return collapseSegments(lines)
    }

    private func headingDateRange(startTime: Date, endTime: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"

        return "\(dateFormatter.string(from: startTime)) \(timeFormatter.string(from: startTime))–\(timeFormatter.string(from: endTime))"
    }

    private func collapseSegments(_ lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return "" }

        var result: [String] = []
        var currentChunk: [String] = []
        var chunkStart = lines[0].timestamp

        for line in lines {
            if line.timestamp - chunkStart > 5, !currentChunk.isEmpty {
                let timestamp = formatTimestamp(chunkStart)
                result.append("[\(timestamp)] \(currentChunk.joined(separator: " "))")
                currentChunk = []
                chunkStart = line.timestamp
            }
            currentChunk.append(line.text)
        }

        if !currentChunk.isEmpty {
            let timestamp = formatTimestamp(chunkStart)
            result.append("[\(timestamp)] \(currentChunk.joined(separator: " "))")
        }

        return result.joined(separator: "\n\n")
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func inferredTitle(from fullText: String) -> String? {
        guard let normalized = trimmedOrNil(
            fullText
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
        ) else {
            return nil
        }

        if normalized == "(Transcription failed)" || normalized == "(No transcript)" {
            return nil
        }

        let sentence = normalized.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? normalized
        guard let trimmedSentence = trimmedOrNil(sentence) else { return nil }

        let bounded = String(trimmedSentence.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOrNil(bounded)
    }

    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func yamlScalar(key: String, value: String?) -> String? {
        guard let value = trimmedOrNil(value) else { return nil }
        return "\(key): \(quotedYAML(value))"
    }

    private func yamlBlock(key: String, value: String?) -> String? {
        guard let value = trimmedOrNil(value) else { return nil }
        let indented = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
        return "\(key): |\n\(indented)"
    }

    private func yamlPerson(key: String, person: MeetingPerson?) -> String? {
        guard let person, !person.isEmpty else { return nil }

        var lines = ["\(key):"]
        if let name = trimmedOrNil(person.name) {
            lines.append("  name: \(quotedYAML(name))")
        }
        if let email = trimmedOrNil(person.email) {
            lines.append("  email: \(quotedYAML(email))")
        }
        return lines.joined(separator: "\n")
    }

    private func yamlPeople(key: String, people: [MeetingPerson]) -> String? {
        let validPeople = people.filter { !$0.isEmpty }
        guard !validPeople.isEmpty else { return nil }

        var lines = ["\(key):"]
        for person in validPeople {
            if let name = trimmedOrNil(person.name), let email = trimmedOrNil(person.email) {
                lines.append("  - name: \(quotedYAML(name))")
                lines.append("    email: \(quotedYAML(email))")
            } else if let name = trimmedOrNil(person.name) {
                lines.append("  - name: \(quotedYAML(name))")
            } else if let email = trimmedOrNil(person.email) {
                lines.append("  - email: \(quotedYAML(email))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func quotedYAML(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
