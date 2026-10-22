import Foundation

/// Storage for reviewer API keys. Keys are never written to `config.json`, which is a plain
/// JSON file in Application Support; they live in the platform's credential store instead —
/// the login Keychain on macOS (`KeychainCredentialStore`), the Credential Manager on Windows
/// (`WindowsCredentialStore`).
///
/// A key is only ever meaningful for a reviewer whose `supportsAPIKeyAuth` is true — either a
/// CLI that reads one from its environment, or a reviewer with no CLI at all, for which a key is
/// the only way in. opencode is neither: it authenticates through its own configuration
/// directory, so Review Bot has nowhere to put a key for it even if one were stored.
protocol CredentialStoring: Sendable {
    func apiKey(for reviewer: ReviewerIdentity) -> String?
    func setAPIKey(_ key: String, for reviewer: ReviewerIdentity) throws
    func removeAPIKey(for reviewer: ReviewerIdentity) throws
}

/// The built-in reviewers are addressed by name in most of the app, so the identity wrapping is
/// done here rather than at two dozen call sites.
extension CredentialStoring {
    func apiKey(for reviewer: ReviewerName) -> String? { apiKey(for: .builtIn(reviewer)) }

    func setAPIKey(_ key: String, for reviewer: ReviewerName) throws {
        try setAPIKey(key, for: .builtIn(reviewer))
    }

    func removeAPIKey(for reviewer: ReviewerName) throws {
        try removeAPIKey(for: .builtIn(reviewer))
    }
}

enum CredentialStoreError: LocalizedError {
    /// A call into the platform's store failed. `store` names it for the message ("Keychain",
    /// "Credential Manager"), `code` is the OS status, and `detail` the OS's own text if any.
    case platform(store: String, code: Int32, detail: String?)

    var errorDescription: String? {
        switch self {
        case let .platform(store, code, detail):
            return "\(store) error \(code)\(detail.map { ": \($0)" } ?? "")."
        }
    }
}

/// The out-of-band key source both platform stores consult before their own storage.
///
/// An explicit environment variable wins, so a development run or a probe can supply a key
/// without touching — or being prompted for — the developer's credential store. Kept in one
/// place so the two stores cannot drift on trimming or on which reviewers are answered.
enum EnvironmentCredentialOverride {
    /// The key `environment` supplies for `reviewer`, trimmed, or `nil` when the variable is
    /// unset or blank.
    ///
    /// `apiKeyOverrideEnvironmentVariable` is total, so it names a variable even for a reviewer
    /// that cannot be handed a key — opencode's `OPENCODE_API_KEY` exists only to keep that
    /// switch exhaustive. Refusing here means an exported value cannot be resolved into a
    /// credential the engine would then have no way to deliver, and cannot make the settings
    /// panel report a key as being "in effect" for a reviewer that ignores it. The predicate is
    /// derived from the reviewer's own surface, so a reviewer that later gains a key variable
    /// starts being answered again without a change here.
    static func apiKey(
        for reviewer: ReviewerIdentity,
        in environment: [String: String]
    ) -> String? {
        guard reviewer.acceptsAPIKey else { return nil }
        let value = environment[reviewer.apiKeyOverrideEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func apiKey(for reviewer: ReviewerName, in environment: [String: String]) -> String? {
        apiKey(for: .builtIn(reviewer), in: environment)
    }
}

/// Non-persistent store used by tests, so the suite never touches the developer's Keychain.
///
/// It carries no `supportsAPIKeyAuth` guard on purpose. That guard exists in the platform stores
/// because they read ambient state — the process environment — and could therefore resolve a
/// key for a reviewer nobody meant to credential. This one returns only what a test explicitly
/// handed it, so guarding would hide a mis-wiring rather than prevent one.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [ReviewerIdentity: String]

    init(keys: [ReviewerIdentity: String] = [:]) {
        self.keys = keys
    }

    /// Convenience for the common case of seeding built-in reviewers by name.
    convenience init(keys: [ReviewerName: String]) {
        self.init(keys: Dictionary(
            uniqueKeysWithValues: keys.map { (ReviewerIdentity.builtIn($0.key), $0.value) }
        ))
    }

    func apiKey(for reviewer: ReviewerIdentity) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[reviewer]
    }

    func setAPIKey(_ key: String, for reviewer: ReviewerIdentity) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if trimmed.isEmpty {
            keys.removeValue(forKey: reviewer)
        } else {
            keys[reviewer] = trimmed
        }
    }

    func removeAPIKey(for reviewer: ReviewerIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        keys.removeValue(forKey: reviewer)
    }
}

/// The reviewer API keys one run needs, read once, up front, off whatever actor asked for them.
///
/// `KeychainCredentialStore.apiKey(for:)` is a synchronous `SecItemCopyMatching`. On a build
/// whose Keychain items are not partition-stable — the ad-hoc-signed default, as the comment
/// in that store explains — that call blocks its thread until the user answers a modal "allow
/// access" dialog. Called from inside an actor-isolated method it blocks the actor's executor,
/// so `ReviewEngine`'s parallel reviewers and the poll loop behind them would all queue up behind
/// one dialog; called on the main actor it freezes the UI. Resolving through this type keeps
/// the blocking read on a detached task, and asks for each key once per run rather than once per
/// place that happens to need it. The Windows store never prompts, but it is a synchronous OS
/// call all the same and goes through here for the same reason.
struct ResolvedCredentials: Sendable {
    private let keys: [ReviewerIdentity: String]

    init(keys: [ReviewerIdentity: String] = [:]) {
        self.keys = keys
    }

    init(keys: [ReviewerName: String]) {
        self.init(keys: Dictionary(
            uniqueKeysWithValues: keys.map { (ReviewerIdentity.builtIn($0.key), $0.value) }
        ))
    }

    /// The key to hand this reviewer, or `nil` if none resolved — because none is saved, because
    /// the Keychain read was refused, or because the reviewer was not one this run asked about.
    func apiKey(for reviewer: ReviewerIdentity) -> String? { keys[reviewer] }

    func apiKey(for reviewer: ReviewerName) -> String? { keys[.builtIn(reviewer)] }

    /// The reviewers a key actually resolved for.
    var reviewersWithKey: Set<ReviewerIdentity> { Set(keys.keys) }

    /// Reads `reviewers`' keys off the calling executor. `await`ing this suspends the caller —
    /// releasing an actor or the main thread — for as long as the store blocks.
    static func resolve(
        _ reviewers: [ReviewerIdentity],
        from store: any CredentialStoring
    ) async -> ResolvedCredentials {
        guard !reviewers.isEmpty else { return ResolvedCredentials() }
        return await Task.detached(priority: .userInitiated) {
            var keys: [ReviewerIdentity: String] = [:]
            for reviewer in reviewers {
                keys[reviewer] = store.apiKey(for: reviewer)
            }
            return ResolvedCredentials(keys: keys)
        }.value
    }

    static func resolve(
        _ reviewers: [ReviewerName],
        from store: any CredentialStoring
    ) async -> ResolvedCredentials {
        await resolve(reviewers.map(ReviewerIdentity.builtIn), from: store)
    }
}
