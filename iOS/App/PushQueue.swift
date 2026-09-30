import Foundation
import Network
import Observation
import UIKit

/// Queues GitHub pushes with retry and offline support.
/// Persists queue to Documents/push-queue.json. Drains on launch and connectivity change.
@MainActor @Observable
final class PushQueue {

    struct PendingPush: Codable, Identifiable {
        let id: UUID
        let filename: String
        let content: String
        let commitMessage: String
        let repo: String
        let basePath: String
        let createdAt: Date
        var retryCount: Int = 0
        var lastError: String? = nil
        /// When set, drain() skips this item until the date passes (rate limit back-off).
        var retryAfter: Date? = nil
    }

    private(set) var pendingCount = 0
    /// Set when a push fails with a credential error (401/403). Cleared when PAT is updated.
    private(set) var credentialError: String? = nil

    var settings: SettingsStore?
    var onPushSuccess: ((PendingPush) -> Void)?

    /// Read-only view of the queue — for status UI.
    var items: [PendingPush] { queue }

    /// Clear the credential error after the PAT has been updated.
    func clearCredentialError() { credentialError = nil }

    private var queue: [PendingPush] = []
    private let github: GitHubSync
    private let monitor = NWPathMonitor()
    private let queueURLOverride: URL?
    private let canDrainNowOverride: Bool?
    private let pushOperation: (@Sendable (PendingPush) async throws -> Void)?
    private var currentPath: NWPath?
    private var isDraining = false
    private var needsDrainAfterCurrentRun = false
    private var batteryObserver: NSObjectProtocol?

    private var queueURL: URL? {
        queueURLOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("push-queue.json")
    }

    init(
        github: GitHubSync = GitHubSync(),
        queueURLOverride: URL? = nil,
        shouldStartMonitoring: Bool = true,
        shouldStartBatteryMonitoring: Bool = true,
        canDrainNowOverride: Bool? = nil,
        pushOperation: (@Sendable (PendingPush) async throws -> Void)? = nil
    ) {
        self.github = github
        self.queueURLOverride = queueURLOverride
        self.canDrainNowOverride = canDrainNowOverride
        self.pushOperation = pushOperation

        loadQueue()
        if shouldStartMonitoring {
            self.startMonitoring()
        }
        if shouldStartBatteryMonitoring {
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.startBatteryMonitoring()
        }
    }

    /// Add a transcript to the push queue and attempt a push when conditions allow.
    func enqueue(filename: String, content: String, commitMessage: String, repo: String, basePath: String) {
        let item = PendingPush(
            id: UUID(),
            filename: filename,
            content: content,
            commitMessage: commitMessage,
            repo: repo,
            basePath: basePath,
            createdAt: Date()
        )
        queue.append(item)
        pendingCount = queue.count
        saveQueue()
        PerformanceTrace.emitEvent("PushQueueEnqueue", detail: "count=\(queue.count)")
        if isDraining {
            needsDrainAfterCurrentRun = true
        } else {
            drain()
        }
    }

    /// Attempt to push all queued items.
    func drain() {
        guard !queue.isEmpty else { return }
        guard !isDraining else {
            needsDrainAfterCurrentRun = true
            return
        }
        guard canDrainNow else {
            PerformanceTrace.emitEvent("PushQueueDeferred", detail: deferredReason)
            return
        }
        isDraining = true
        let signpost = PerformanceTrace.beginInterval("PushQueueDrain", detail: "count=\(queue.count)")

        Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                let shouldRedrain = self.needsDrainAfterCurrentRun
                self.needsDrainAfterCurrentRun = false
                self.pendingCount = self.queue.count
                self.saveQueue()
                self.isDraining = false
                PerformanceTrace.endInterval("PushQueueDrain", state: signpost, detail: "remaining=\(self.queue.count)")

                if shouldRedrain, !self.queue.isEmpty, self.canDrainNow {
                    self.drain()
                }
            }

            let initialIDs = self.queue.map(\.id)

            for id in initialIDs {
                guard self.canDrainNow else {
                    PerformanceTrace.emitEvent("PushQueueDeferred", detail: self.deferredReason)
                    break
                }
                guard let item = self.queue.first(where: { $0.id == id }) else { continue }

                // Skip items that are rate-limited until their retry window expires.
                if let retryAfter = item.retryAfter, retryAfter > Date() { continue }

                do {
                    try await self.performPush(for: item)
                    self.removePendingPush(id: id)
                    self.onPushSuccess?(item)
                } catch let syncError as GitHubSync.SyncError {
                    if case .rateLimited(let seconds) = syncError {
                        self.updatePendingPush(id: id) { pending in
                            pending.lastError = syncError.localizedDescription
                            pending.retryAfter = Date().addingTimeInterval(seconds)
                        }
                        break
                    }
                    if syncError.isCredentialError {
                        self.credentialError = "GitHub access denied — update your token in Settings."
                        self.updatePendingPush(id: id) { pending in
                            pending.lastError = syncError.localizedDescription
                        }
                        // Don't break — try remaining items (they'll fail too, but surfaces all errors)
                        continue
                    }
                    let isRetryable = syncError.isRetryable
                    self.updatePendingPush(id: id) { pending in
                        pending.lastError = syncError.localizedDescription
                        if isRetryable { pending.retryCount += 1 }
                    }
                    if isRetryable { break }
                } catch {
                    self.updatePendingPush(id: id) { pending in
                        pending.lastError = error.localizedDescription
                        pending.retryCount += 1
                    }
                    break
                }
            }
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

    private var canDrainNow: Bool {
        if let canDrainNowOverride {
            return canDrainNowOverride
        }

        guard let currentPath, currentPath.status == .satisfied else { return false }
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let isWiFi = currentPath.usesInterfaceType(.wifi) && !currentPath.isExpensive
        let mode = settings?.pushMode ?? .immediate

        switch mode {
        case .immediate:
            return true
        case .wifiOnly:
            return isWiFi
        case .chargingOnly:
            return isCharging
        case .wifiOrCharging:
            return isWiFi || isCharging
        }
    }

    private var deferredReason: String {
        if let canDrainNowOverride {
            return canDrainNowOverride ? "ready" : "blocked-by-override"
        }

        guard let currentPath, currentPath.status == .satisfied else {
            return "waiting-for-network"
        }
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let isWiFi = currentPath.usesInterfaceType(.wifi) && !currentPath.isExpensive
        switch settings?.pushMode ?? .immediate {
        case .immediate:
            return "ready"
        case .wifiOnly:
            return isWiFi ? "ready" : "waiting-for-wifi"
        case .chargingOnly:
            return isCharging ? "ready" : "waiting-for-charging"
        case .wifiOrCharging:
            return (isWiFi || isCharging) ? "ready" : "waiting-for-wifi-or-charging"
        }
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.currentPath = path
                if path.status == .satisfied {
                    self?.drain()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tokdown.network-monitor"))
    }

    private func startBatteryMonitoring() {
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drain()
            }
        }
    }

    private func performPush(for item: PendingPush) async throws {
        if let pushOperation {
            try await pushOperation(item)
            return
        }

        try await github.push(
            filename: item.filename,
            content: item.content,
            commitMessage: item.commitMessage,
            repo: item.repo,
            basePath: item.basePath
        )
    }

    private func removePendingPush(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index)
    }

    private func updatePendingPush(id: UUID, update: (inout PendingPush) -> Void) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        update(&queue[index])
    }

}
