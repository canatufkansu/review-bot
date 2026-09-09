import Foundation
import WinSDK

/// Reviewer API keys in the Windows Credential Manager, as generic credentials under
/// `Review Bot reviewer API keys/<reviewer>`. They are encrypted under the user's login (DPAPI)
/// and readable by any process running as that user, so — unlike the macOS Keychain — a rebuilt
/// binary is never prompted for access and there is nothing to re-authorise after `swift build`.
///
/// Persisted as `CRED_PERSIST_LOCAL_MACHINE`: the key survives log-off and reboot on this
/// machine and is not roamed to other machines by a domain profile, which is the right scope
/// for a key that bills the developer's own account.
struct WindowsCredentialStore: CredentialStoring {
    private let service: String
    /// Consulted before the Credential Manager, so a key can be supplied out-of-band. Injected
    /// rather than read at the point of use so tests can exercise the override without a real key.
    private let environment: [String: String]

    init(
        service: String = "Review Bot reviewer API keys",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.service = service
        self.environment = environment
    }

    func apiKey(for reviewer: ReviewerName) -> String? {
        guard reviewer.supportsAPIKeyAuth else { return nil }
        if let fromEnvironment = EnvironmentCredentialOverride.apiKey(for: reviewer, in: environment) {
            return fromEnvironment
        }
        return read(target(for: reviewer))
    }

    func setAPIKey(_ key: String, for reviewer: ReviewerName) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeAPIKey(for: reviewer)
            return
        }
        try write(target(for: reviewer), secret: trimmed)
    }

    /// Deliberately unguarded by `supportsAPIKeyAuth`, unlike `apiKey(for:)`: an item saved by
    /// an earlier build, or before a reviewer's auth surface changed, must stay removable.
    func removeAPIKey(for reviewer: ReviewerName) throws {
        let deleted = target(for: reviewer).withCString(encodedAs: UTF16.self) { name in
            CredDeleteW(name, Self.genericType, 0)
        }
        guard !deleted.boolValue else { return }
        let error = GetLastError()
        guard error == Self.errorNotFound else {
            throw CredentialStoreError.platform(
                store: "Credential Manager",
                code: Int32(bitPattern: error),
                detail: nil
            )
        }
    }

    // MARK: - Credential Manager calls

    // `wincred.h` constants, restated: the header defines them as macros, which do not import.
    private static let genericType: DWORD = 1 // CRED_TYPE_GENERIC
    private static let persistLocalMachine: DWORD = 2 // CRED_PERSIST_LOCAL_MACHINE
    private static let errorNotFound: DWORD = 1168 // ERROR_NOT_FOUND

    private func target(for reviewer: ReviewerName) -> String {
        "\(service)/\(reviewer.rawValue)"
    }

    private func read(_ target: String) -> String? {
        var credential: PCREDENTIALW?
        let found = target.withCString(encodedAs: UTF16.self) { name in
            CredReadW(name, Self.genericType, 0, &credential)
        }
        guard found.boolValue, let credential else { return nil }
        defer { CredFree(credential) }
        let size = Int(credential.pointee.CredentialBlobSize)
        guard size > 0, let blob = credential.pointee.CredentialBlob else { return nil }
        let value = String(decoding: UnsafeBufferPointer(start: blob, count: size), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func write(_ target: String, secret: String) throws {
        var bytes = Array(secret.utf8)
        let written = target.withCString(encodedAs: UTF16.self) { name in
            "Review Bot".withCString(encodedAs: UTF16.self) { user in
                bytes.withUnsafeMutableBufferPointer { blob in
                    var credential = CREDENTIALW()
                    credential.Type = Self.genericType
                    credential.TargetName = UnsafeMutablePointer(mutating: name)
                    credential.CredentialBlobSize = DWORD(blob.count)
                    credential.CredentialBlob = blob.baseAddress
                    credential.Persist = Self.persistLocalMachine
                    credential.UserName = UnsafeMutablePointer(mutating: user)
                    return CredWriteW(&credential, 0)
                }
            }
        }
        guard written.boolValue else {
            throw CredentialStoreError.platform(
                store: "Credential Manager",
                code: Int32(bitPattern: GetLastError()),
                detail: nil
            )
        }
    }
}
