import Foundation
import Network
import Observation

/// Queues GitHub pushes with retry and offline support.
/// Persists queue to Documents/push-queue.json. Drains on launch and connectivity change.
@MainActor @Observable
final class PushQueue {

    struct PendingPush: Codable, Identifiable {
        let id: UUID
        let filename: String
        let content: String
        let commitMessage: String
        let createdAt: Date
        var retryCount: Int = 0
    }

    private(set) var pendingCount = 0

    private var queue: [PendingPush] = []
    private let github = GitHubSync()
    private let monitor = NWPathMonitor()
    private var isDraining = false

    private var queueURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("push-queue.json")
    }

    init() {
        loadQueue()
        startMonitoring()
    }

    /// Add a transcript to the push queue and attempt immediate push.
    func enqueue(filename: String, content: String, commitMessage: String) {
        let item = PendingPush(
            id: UUID(),
            filename: filename,
            content: content,
            commitMessage: commitMessage,
            createdAt: Date()
        )
        queue.append(item)
        pendingCount = queue.count
        saveQueue()
        drain()
    }

    /// Attempt to push all queued items.
    func drain() {
        guard !isDraining, !queue.isEmpty else { return }
        isDraining = true

        Task { @MainActor in
            var remaining: [PendingPush] = []

            for item in queue {
                do {
                    try await github.push(
                        filename: item.filename,
                        content: item.content,
                        commitMessage: item.commitMessage
                    )
                } catch {
                    var retry = item
                    retry.retryCount += 1
                    if retry.retryCount < 10 { // max 10 retries
                        remaining.append(retry)
                    }
                }
            }

            queue = remaining
            pendingCount = queue.count
            saveQueue()
            isDraining = false
        }
    }

    // MARK: - Persistence

    private func loadQueue() {
        guard let url = queueURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([PendingPush].self, from: data) else {
            return
        }
        queue = items
        pendingCount = queue.count
    }

    private func saveQueue() {
        guard let url = queueURL, let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Network Monitoring

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor [weak self] in
                    self?.drain()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tokdown.network-monitor"))
    }
}
