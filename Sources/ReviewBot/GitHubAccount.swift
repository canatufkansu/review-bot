import Foundation

/// The GitHub accounts `gh` is signed in to, as `gh auth status` reports them.
///
/// Review Bot never holds a GitHub credential of its own: everything goes through the
/// developer's `gh`, and `gh` can be signed in to several accounts at once. Which one Review
/// Bot reviews *as* is a setting (`ReviewBotConfiguration.githubAccount`); this is the list the
/// setting picks from, and `active` is what `gh` itself would use when the setting is blank.
struct GitHubAccounts: Codable, Equatable {
    var accounts: [String]
    var active: String?

    static let none = GitHubAccounts(accounts: [], active: nil)

    /// Parses `gh auth status` output. Only github.com accounts that are actually signed in are
    /// listed; one whose token `gh` reports as invalid is left out, since choosing it would only
    /// produce a poll that fails at the first call.
    ///
    /// The format, per account:
    ///
    ///     github.com
    ///       ✓ Logged in to github.com account alice (keyring)
    ///       - Active account: true
    ///       ...
    ///       ✓ Logged in to github.com account bob (keyring)
    ///       - Active account: false
    static func parse(_ output: String) -> GitHubAccounts {
        var accounts: [String] = []
        var active: String?
        var current: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "Logged in to github.com account ") {
                let rest = line[range.upperBound...]
                let name = String(rest.prefix { !$0.isWhitespace })
                guard !name.isEmpty else { continue }
                current = name
                if !accounts.contains(name) { accounts.append(name) }
            } else if line.hasPrefix("Failed to log in") || line.hasPrefix("X Failed") {
                current = nil
            } else if line.hasPrefix("- Active account: true"), let current {
                active = current
            }
        }
        return GitHubAccounts(accounts: accounts, active: active)
    }
}

/// The environment that makes one poll act as a chosen account: `gh` reads `GH_TOKEN` ahead of
/// its own active account, and `git` is told — for this run only, through the `GIT_CONFIG_*`
/// variables git reads before any config file — to take github.com credentials from
/// `gh auth git-credential`, which honours the same `GH_TOKEN`. So the review requests found,
/// the fetch, and the posted review all belong to the same account, and nothing on the machine
/// (gh's active account, git's global credential helper) is changed to get there.
enum GitHubAccountEnvironment {
    static func overrides(token: String) -> EnvironmentOverrides {
        [
            "GH_TOKEN": token,
            "GIT_CONFIG_COUNT": "2",
            // An empty value first resets whatever helpers the user's config lists for the
            // host, so the token is not handed to a helper that would answer with another one.
            "GIT_CONFIG_KEY_0": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_0": "",
            "GIT_CONFIG_KEY_1": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_1": "!gh auth git-credential",
        ]
    }
}

/// A `CommandRunning` that adds an environment to every `gh` and `git` it runs and passes
/// everything else through untouched.
///
/// The engine invokes `gh` and `git` from two dozen places; wrapping the runner for the
/// duration of a poll is what keeps the account decision in one place rather than threaded
/// through each of them. Reviewer CLIs are deliberately not scoped: a `GH_TOKEN` in a
/// reviewer's environment would be a credential it has no business seeing.
struct AccountScopedRunner: CommandRunning {
    let base: any CommandRunning
    let overrides: EnvironmentOverrides

    static let scopedCommands: Set<String> = ["gh", "git"]

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: [:],
            timeout: timeout
        )
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult {
        var merged = environment
        if Self.scopedCommands.contains(executable) {
            // The caller's own overrides win, so a deliberate per-command choice is never
            // undone by the account scope.
            for (key, value) in overrides where merged[key] == nil {
                merged[key] = value
            }
        }
        return try await base.run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: merged,
            timeout: timeout
        )
    }
}
