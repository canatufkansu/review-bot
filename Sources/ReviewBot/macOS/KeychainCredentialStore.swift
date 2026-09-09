import Foundation
import Security

struct KeychainCredentialStore: CredentialStoring {
    /// Deliberately uses the file-based login Keychain rather than the data-protection
    /// Keychain: the latter needs an `application-identifier` entitlement, which an
    /// ad-hoc-signed build (the default for `make app`) does not have.
    private let service: String
    /// Consulted before the Keychain, so a key can be supplied out-of-band. Injected rather
    /// than read at the point of use so tests can exercise the override without a real key.
    private let environment: [String: String]

    init(
        service: String = "Review Bot reviewer API keys",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.service = service
        self.environment = environment
    }

    func apiKey(for reviewer: ReviewerName) -> String? {
        // The guard lives in `EnvironmentCredentialOverride` too, but it is restated here so a
        // Keychain item saved for a reviewer that has since lost its key path is not resolved.
        guard reviewer.supportsAPIKeyAuth else { return nil }

        if let fromEnvironment = EnvironmentCredentialOverride.apiKey(for: reviewer, in: environment) {
            return fromEnvironment
        }

        var query = baseQuery(for: reviewer)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func setAPIKey(_ key: String, for reviewer: ReviewerName) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeAPIKey(for: reviewer)
            return
        }

        let query = baseQuery(for: reviewer)
        let attributes = [kSecValueData as String: Data(trimmed.utf8)] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Self.error(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = Data(trimmed.utf8)
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.error(addStatus)
        }
    }

    /// Deliberately unguarded by `supportsAPIKeyAuth`, unlike `apiKey(for:)`: an item saved by
    /// an earlier build, or before a reviewer's auth surface changed, must stay removable.
    func removeAPIKey(for reviewer: ReviewerName) throws {
        let status = SecItemDelete(baseQuery(for: reviewer) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status)
        }
    }

    private static func error(_ status: OSStatus) -> CredentialStoreError {
        .platform(
            store: "Keychain",
            code: status,
            detail: SecCopyErrorMessageString(status, nil) as String?
        )
    }

    private func baseQuery(for reviewer: ReviewerName) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reviewer.rawValue,
        ]
    }

    // Two things that look like they would stop macOS re-prompting for this item after every
    // rebuild, both measured not to work. Don't spend the afternoon again.
    //
    // 1. `kSecAttrAccess` with a nil application list ("any application, never ask"). Every item
    //    also carries a *partition list*, checked independently of the trusted-application list.
    //    It is stamped `cdhash:<saving binary>` when the signature has no team identity, so a
    //    rebuilt binary fails it whatever the ACL says.
    // 2. A self-signed code-signing identity. It fixes the ACL half — the requirement becomes
    //    `identifier "…" and certificate leaf = H"…"`, which a rebuild does satisfy — but the
    //    partition list is still `cdhash:` because a self-signed cert carries no team id, so a
    //    rebuild is still refused.
    //
    // The partition list only becomes rebuild-stable when it can record `teamid:`, which needs a
    // real (Apple-issued) signing identity: `CODE_SIGN_IDENTITY="Developer ID Application: …"`.
    // Failing that, `ReviewerName.apiKeyOverrideEnvironmentVariable` avoids the Keychain
    // altogether for development runs.
}
