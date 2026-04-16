import XCTest
@testable import TokDown

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeSuite() -> UserDefaults {
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        addTeardownBlock { suite.removePersistentDomain(forName: suite.description) }
        return suite
    }

    func testSaveAndLoadRoundTrips() {
        let suite = makeSuite()
        let store = SettingsStore(defaults: suite)

        store.settings.audioSource = .microphone
        store.settings.saveFolderPath = "/tmp/custom"
        store.save()

        let restored = SettingsStore(defaults: suite)
        XCTAssertEqual(restored.settings.audioSource, .microphone)
        XCTAssertEqual(restored.settings.saveFolderPath, "/tmp/custom")
    }

    func testMissingKeyReturnsDefaults() {
        let suite = makeSuite()
        let store = SettingsStore(defaults: suite)

        XCTAssertEqual(store.settings.audioSource, .systemAudio)
        XCTAssertTrue(store.settings.saveFolderPath.contains("Transcripts"))
    }

    func testCorruptDataReturnsDefaults() {
        let suite = makeSuite()
        suite.set(Data("not-json".utf8), forKey: "TokDown.Settings.V2")

        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.settings.audioSource, .systemAudio)
        XCTAssertTrue(store.settings.saveFolderPath.contains("Transcripts"))
    }
}
