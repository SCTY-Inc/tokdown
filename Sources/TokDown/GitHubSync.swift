import Foundation
import Security

/// Pushes markdown transcripts to GitHub via the Contents API.
///
/// Target: PUT https://api.github.com/repos/amadad/agents/contents/intel/transcripts/{filename}
/// Auth:   Bearer {PAT} from Keychain (service: "tokdown")
actor GitHubSync {

    enum SyncError: Error, Sendable {
        case missingPAT
        case encodingFailed
        case httpError(statusCode: Int, message: String)
        case networkError(Error)
    }

    private let repo = "amadad/agents"
    private let basePath = "intel/transcripts"
    private static let keychainService = "tokdown"
    private static let keychainAccount = "github-pat"

    /// Push a transcript markdown file to GitHub.
    /// - Parameters:
    ///   - filename: e.g. "2026-04-01_10-00_Standup.md"
    ///   - content: Full markdown string
    ///   - commitMessage: e.g. "transcript: Standup"
    func push(filename: String, content: String, commitMessage: String) async throws {
        guard let pat = loadPAT() else {
            throw SyncError.missingPAT
        }

        guard let contentData = content.data(using: .utf8) else {
            throw SyncError.encodingFailed
        }
        let base64Content = contentData.base64EncodedString()

        let existingSHA = try await checkExisting(filename: filename)

        let urlString = "https://api.github.com/repos/\(repo)/contents/\(basePath)/\(filename)"
        guard let url = URL(string: urlString) else {
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
            throw SyncError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.httpError(statusCode: 0, message: "Not an HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SyncError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    /// Check if a transcript already exists on GitHub.
    /// - Parameter filename: File name within basePath
    /// - Returns: The file's SHA if it exists, nil otherwise
    func checkExisting(filename: String) async throws -> String? {
        guard let pat = loadPAT() else {
            throw SyncError.missingPAT
        }

        let urlString = "https://api.github.com/repos/\(repo)/contents/\(basePath)/\(filename)"
        guard let url = URL(string: urlString) else { return nil }

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
