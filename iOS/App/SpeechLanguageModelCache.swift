import Foundation
import CryptoKit
import Speech

/// Builds and caches lightweight custom language models from contextual phrases.
actor SpeechLanguageModelCache {

    private var cachedKey: String?
    private var cachedLocaleIdentifier: String?
    private var cachedConfiguration: SFSpeechLanguageModel.Configuration?

    func configuration(for phrases: [String], locale: Locale) async -> SFSpeechLanguageModel.Configuration? {
        guard #available(iOS 17, *) else { return nil }

        let normalizedPhrases = Self.normalize(phrases)
        guard normalizedPhrases.count >= 3 else { return nil }

        let key = Self.cacheKey(for: normalizedPhrases)
        if cachedKey == key,
           cachedLocaleIdentifier == locale.identifier,
           let cachedConfiguration {
            return cachedConfiguration
        }

        do {
            let configuration = try await buildConfiguration(for: normalizedPhrases, locale: locale, key: key)
            cachedKey = key
            cachedLocaleIdentifier = locale.identifier
            cachedConfiguration = configuration
            return configuration
        } catch {
            DebugLog.write("custom language model build failed: \(error.localizedDescription)")
            return nil
        }
    }

    @available(iOS 17, *)
    private func buildConfiguration(
        for phrases: [String],
        locale: Locale,
        key: String
    ) async throws -> SFSpeechLanguageModel.Configuration {
        let directory = try modelDirectory()
        let assetURL = directory.appendingPathComponent("\(key)-asset").appendingPathExtension("bin")
        let modelURL = directory.appendingPathComponent("\(key)-lm").appendingPathExtension("bin")
        let vocabularyURL = directory.appendingPathComponent("\(key)-vocab").appendingPathExtension("bin")

        let modelData = SFCustomLanguageModelData(
            locale: locale,
            identifier: "com.amadad.tokdown.customlm",
            version: key
        )
        for phrase in phrases {
            modelData.insert(phraseCount: .init(phrase: phrase, count: 8))
            for component in phrase
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter({ $0.count >= 3 }) {
                modelData.insert(phraseCount: .init(phrase: component, count: 2))
            }
        }
        try await modelData.export(to: assetURL)

        let configuration = SFSpeechLanguageModel.Configuration(
            languageModel: modelURL,
            vocabulary: vocabularyURL
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SFSpeechLanguageModel.prepareCustomLanguageModel(for: assetURL, configuration: configuration) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        return configuration
    }

    private func modelDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokDownCustomLanguageModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func normalize(_ phrases: [String]) -> [String] {
        Array(Set(
            phrases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
        .sorted()
    }

    static func cacheKey(for phrases: [String]) -> String {
        let joined = normalize(phrases).joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
