import Foundation
import Testing
@testable import TokDown

private actor Signal {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        isSignaled = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor Recorder {
    private var filenames: [String] = []

    func record(_ filename: String) {
        filenames.append(filename)
    }

    func snapshot() -> [String] {
        filenames
    }
}

@Suite("PushQueue")
struct PushQueueTests {

    @Test("Pending push preserves repo and basePath across persistence")
    func pendingPushCodableRoundTrip() throws {
        let original = PushQueue.PendingPush(
            id: UUID(),
            filename: "2026-04-11_10-30_Standup.md",
            content: "# Standup",
            commitMessage: "transcript: Standup",
            repo: "SCTY-Inc/transcripts",
            basePath: "intel/transcripts",
            createdAt: Date(timeIntervalSince1970: 1_775_903_400)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PushQueue.PendingPush.self, from: data)

        #expect(decoded.repo == original.repo)
        #expect(decoded.basePath == original.basePath)
        #expect(decoded.filename == original.filename)
        #expect(decoded.commitMessage == original.commitMessage)
    }

    @MainActor
    @Test("Drain keeps items enqueued while a push is in flight")
    func drainKeepsItemsEnqueuedWhilePushing() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let firstPushStarted = Signal()
        let allowFirstPushToFinish = Signal()
        let recorder = Recorder()

        let queue = PushQueue(
            queueURLOverride: tempDirectory.appendingPathComponent("push-queue.json"),
            shouldStartMonitoring: false,
            shouldStartBatteryMonitoring: false,
            canDrainNowOverride: true,
            pushOperation: { item in
                await recorder.record(item.filename)
                if item.filename == "first.md" {
                    await firstPushStarted.signal()
                    await allowFirstPushToFinish.wait()
                }
            }
        )

        queue.enqueue(
            filename: "first.md",
            content: "one",
            commitMessage: "first",
            repo: "owner/repo",
            basePath: "transcripts"
        )
        await firstPushStarted.wait()

        queue.enqueue(
            filename: "second.md",
            content: "two",
            commitMessage: "second",
            repo: "owner/repo",
            basePath: "transcripts"
        )
        await allowFirstPushToFinish.signal()

        for _ in 0..<100 {
            if queue.pendingCount == 0, await recorder.snapshot().count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await recorder.snapshot() == ["first.md", "second.md"])
        #expect(queue.pendingCount == 0)
    }
}

@Suite("SpeechLanguageModelCache")
struct SpeechLanguageModelCacheTests {

    @Test("Cache key is deterministic")
    func cacheKeyIsDeterministic() {
        let key = SpeechLanguageModelCache.cacheKey(for: ["Zoom", "Alice", "TokDown"])
        #expect(key == "7af1da8d4ccd56311313d0c99a7a4f12d1c383e5cb6b34b7f2b019a1044e8f29")
    }
}
