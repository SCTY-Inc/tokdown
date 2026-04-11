import Foundation
import Testing
@testable import TokDown

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
}
