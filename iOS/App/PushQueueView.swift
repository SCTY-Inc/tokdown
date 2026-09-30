import SwiftUI

/// Shows all items currently in the push queue with their status, retry count, and last error.
struct PushQueueView: View {

    @Environment(SessionManager.self) var session

    var body: some View {
        Group {
            if session.pushQueue.items.isEmpty {
                ContentUnavailableView(
                    "Queue Empty",
                    systemImage: "checkmark.circle",
                    description: Text("All transcripts have been pushed to GitHub.")
                )
            } else {
                List {
                    ForEach(session.pushQueue.items) { item in
                        PushQueueItemRow(item: item)
                    }
                }
            }
        }
        .navigationTitle("Push Queue")
        .toolbar {
            if !session.pushQueue.items.isEmpty {
                Button("Retry All") {
                    session.pushQueue.drain()
                }
            }
        }
    }
}

private struct PushQueueItemRow: View {

    let item: PushQueue.PendingPush

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }

            if let error = item.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                if item.retryCount > 0 {
                    Label("\(item.retryCount) retr\(item.retryCount == 1 ? "y" : "ies")", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let retryAfter = item.retryAfter, retryAfter > Date() {
                    Label("Rate limited", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Strip the date/time prefix from filenames like "2026-04-15_10-30-00-000_Title.md".
    private var displayTitle: String {
        let parts = item.filename
            .replacingOccurrences(of: ".md", with: "")
            .components(separatedBy: "_")
            .dropFirst(2)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return parts.isEmpty ? item.filename : parts
    }

    private var statusBadge: some View {
        Group {
            if let retryAfter = item.retryAfter, retryAfter > Date() {
                Label("Rate limited", systemImage: "clock")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
            } else if item.lastError != nil {
                Label("Failed", systemImage: "exclamationmark.triangle")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.red.opacity(0.1), in: Capsule())
            } else {
                Label("Queued", systemImage: "clock")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
        }
    }
}
