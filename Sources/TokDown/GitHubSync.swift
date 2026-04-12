import Foundation
import Security

/// Pushes markdown transcripts to GitHub via the Contents API.
///
/// Auth: Bearer {PAT} from Keychain (service: "tokdown")
actor GitHubSync {

    enum SyncError: Error, Sendable, LocalizedError {
        case missingPAT
        case missingRepo
        case encodingFailed
        case httpError(statusCode: Int, message: String)
        case networkError(Error)

        var isRetryable: Bool {
            switch self {
            case .networkError:
                true
            case .httpError(let statusCode, _):
                statusCode == 408 || statusCode == 409 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
            case .missingPAT, .missingRepo, .encodingFailed:
                false
            }
        }

        var errorDescription: String? {
            switch self {
            case .missingPAT:
                "GitHub personal access token is missing"
            case .missingRepo:
                "GitHub repository is missing"
            case .encodingFailed:
                "Couldn't encode the GitHub request"
            case .httpError(let statusCode, let message):
                "GitHub API error (\(statusCode)): \(message)"
            case .networkError(let error):
                "GitHub network error: \(error.localizedDescription)"
            }
        }
    }

    private static let keychainService = "tokdown"
    private static let keychainAccount = "github-pat"

    /// Push a transcript markdown file to GitHub.
    /// - Parameters:
    ///   - filename: e.g. "2026-04-01_10-00_Standup.md"
    ///   - content: Full markdown string
    ///   - commitMessage: e.g. "transcript: Standup"
    ///   - repo: GitHub repository in `owner/name` form
    ///   - basePath: Directory path inside the repository
    func push(
        filename: String,
        content: String,
        commitMessage: String,
        repo: String,
        basePath: String
    ) async throws {
        let signpost = PerformanceTrace.beginInterval("GitHubPush", detail: filename)
        defer { PerformanceTrace.endInterval("GitHubPush", state: signpost, detail: filename) }

        guard !repo.isEmpty else {
            throw SyncError.missingRepo
        }
        guard let pat = loadPAT() else {
            throw SyncError.missingPAT
        }

        guard let contentData = content.data(using: .utf8) else {
            throw SyncError.encodingFailed
        }
        let base64Content = contentData.base64EncodedString()

        let existingSHA = try await checkExisting(filename: filename, repo: repo, basePath: basePath, pat: pat)

        guard let url = Self.contentsURL(repo: repo, basePath: basePath, filename: filename) else {
            throw SyncError.encodingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        var body: [String: String] = [
            "message": commitMessage,
            "content": base64Content
        ]
        if let sha = existingSHA {
            body["sha"] = sha
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            PerformanceTrace.emitEvent("GitHubPushFailure", detail: filename)
            DebugLog.write("GitHub push network error file=\(filename) error=\(error.localizedDescription)")
            throw SyncError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.httpError(statusCode: 0, message: "Not an HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            DebugLog.write("GitHub push HTTP error file=\(filename) status=\(httpResponse.statusCode)")
            throw SyncError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        PerformanceTrace.emitEvent("GitHubPushSuccess", detail: filename)
        DebugLog.write("GitHub push success file=\(filename)")
    }

    /// Check if a transcript already exists on GitHub.
    /// - Parameter filename: File name within basePath
    /// - Returns: The file's SHA if it exists, nil otherwise
    private func checkExisting(filename: String, repo: String, basePath: String, pat: String) async throws -> String? {
        guard let url = Self.contentsURL(repo: repo, basePath: basePath, filename: filename) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else { return nil }

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sha = json["sha"] as? String {
            return sha
        }

        return nil
    }

    static func contentsURL(repo: String, basePath: String, filename: String) -> URL? {
        let repoSegments = repo.split(separator: "/").map(String.init)
        guard repoSegments.count == 2, var url = URL(string: "https://api.github.com/repos") else {
            return nil
        }

        for segment in repoSegments {
            url.appendPathComponent(segment)
        }
        url.appendPathComponent("contents")

        for segment in basePath.split(separator: "/").map(String.init) {
            url.appendPathComponent(segment)
        }
        url.appendPathComponent(filename)
        return url
    }

    // MARK: - Keychain

    /// Load GitHub PAT from Keychain.
    func loadPAT() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Save GitHub PAT to Keychain. Updates existing item if present.
    func savePAT(_ token: String) throws {
        guard let tokenData = token.data(using: .utf8) else {
            throw SyncError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]

        let existing = SecItemCopyMatching(query as CFDictionary, nil)

        if existing == errSecSuccess {
            let update: [String: Any] = [
                kSecValueData as String: tokenData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status != errSecSuccess {
                throw SyncError.httpError(statusCode: Int(status), message: "Keychain update failed: \(status)")
            }
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = tokenData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                throw SyncError.httpError(statusCode: Int(status), message: "Keychain add failed: \(status)")
            }
        }
    }

    /// Delete GitHub PAT from Keychain.
    func deletePAT() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
