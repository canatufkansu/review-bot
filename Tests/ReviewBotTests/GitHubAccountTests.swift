import Foundation
import XCTest
@testable import ReviewBot

final class GitHubAccountTests: XCTestCase {
    private let status = """
    github.com
      ✓ Logged in to github.com account alice (keyring)
      - Active account: true
      - Git operations protocol: https
      - Token: gho_************************************
      - Token scopes: 'gist', 'read:org', 'repo', 'workflow'

      ✓ Logged in to github.com account bob (keyring)
      - Active account: false
      - Git operations protocol: https
      - Token: gho_************************************

      X Failed to log in to github.com account carol (default)
      - Active account: false
      - The token in default is invalid.
    """

    func testParsesSignedInAccountsAndTheActiveOne() {
        let accounts = GitHubAccounts.parse(status)
        XCTAssertEqual(accounts.accounts, ["alice", "bob"])
        XCTAssertEqual(accounts.active, "alice")
    }

    func testAnAccountWhoseTokenIsBrokenIsNotOffered() {
        XCTAssertFalse(GitHubAccounts.parse(status).accounts.contains("carol"))
    }

    func testNothingSignedInParsesToNone() {
        XCTAssertEqual(GitHubAccounts.parse("You are not logged into any GitHub hosts. To log in, run: gh auth login"), .none)
        XCTAssertEqual(GitHubAccounts.parse(""), .none)
    }

    func testTheSettingIsTrimmedAndSurvivesAnOlderConfig() throws {
        let older = Data("{\"repositories\":[],\"pollIntervalMinutes\":15}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(ReviewBotConfiguration.self, from: older).githubAccount, "")
        let spaced = Data("{\"githubAccount\":\"  bob \"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(ReviewBotConfiguration.self, from: spaced).githubAccount, "bob")
        XCTAssertEqual(ReviewBotConfiguration.default.githubAccount, "")
    }

    // MARK: - The scoped runner

    private final class RecordingRunner: CommandRunning, @unchecked Sendable {
        var calls: [(executable: String, environment: EnvironmentOverrides)] = []
        var watches: [OutputWatch?] = []

        func run(_ executable: String, arguments: [String], currentDirectory: URL?, timeout: Int) async throws -> CommandResult {
            try await run(executable, arguments: arguments, currentDirectory: currentDirectory, environment: [:], timeout: timeout)
        }

        func run(_ executable: String, arguments: [String], currentDirectory: URL?, environment: EnvironmentOverrides, timeout: Int) async throws -> CommandResult {
            try await run(executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment, stopEarly: nil, timeout: timeout)
        }

        func run(_ executable: String, arguments: [String], currentDirectory: URL?, environment: EnvironmentOverrides, stopEarly: OutputWatch?, timeout: Int) async throws -> CommandResult {
            calls.append((executable, environment))
            watches.append(stopEarly)
            return CommandResult(command: executable, exitCode: 0, stdout: "", stderr: "")
        }
    }

    /// The protocol's default for the watching overload drops the watch. The scoped runner
    /// wraps every reviewer run whenever an account is chosen, so if it fell back to that
    /// default a stuck reviewer would wait out its whole time limit on every such review.
    func testTheScopedRunnerForwardsTheOutputWatch() async throws {
        let base = RecordingRunner()
        let scoped = AccountScopedRunner(base: base, overrides: GitHubAccountEnvironment.overrides(token: "gho_alice"))

        _ = try await scoped.run(
            "opencode", arguments: ["run"], currentDirectory: nil, environment: [:],
            stopEarly: { $0.contains("usage limit") }, timeout: 5
        )
        _ = try await scoped.run("gh", arguments: ["api", "user"], timeout: 5)

        XCTAssertEqual(base.watches.count, 2)
        XCTAssertNotNil(base.watches[0], "the reviewer's watch must reach the base runner")
        XCTAssertTrue(base.watches[0]?("Go usage limit exceeded") == true)
        XCTAssertNil(base.watches[1])
        XCTAssertEqual(base.calls[0].environment.count, 0, "a reviewer never sees the token")
    }

    func testOnlyGhAndGitAreScopedAndTheCallersOwnOverridesWin() async throws {
        let base = RecordingRunner()
        let scoped = AccountScopedRunner(base: base, overrides: GitHubAccountEnvironment.overrides(token: "gho_alice"))

        _ = try await scoped.run("gh", arguments: ["api", "user"], timeout: 5)
        _ = try await scoped.run("git", arguments: ["fetch"], currentDirectory: nil, environment: ["GH_TOKEN": "explicit"], timeout: 5)
        _ = try await scoped.run("claude", arguments: ["-p", "review"], currentDirectory: nil, environment: ["ANTHROPIC_API_KEY": nil], timeout: 5)

        XCTAssertEqual(base.calls.map(\.executable), ["gh", "git", "claude"])
        XCTAssertEqual(base.calls[0].environment["GH_TOKEN"], "gho_alice")
        XCTAssertEqual(base.calls[0].environment["GIT_CONFIG_VALUE_1"], "!gh auth git-credential")
        // The caller's own value for the same variable is kept.
        XCTAssertEqual(base.calls[1].environment["GH_TOKEN"], "explicit")
        XCTAssertEqual(base.calls[1].environment["GIT_CONFIG_COUNT"], "2")
        // A reviewer never sees the GitHub token, and its own overrides are untouched.
        XCTAssertNil(base.calls[2].environment["GH_TOKEN"])
        XCTAssertEqual(base.calls[2].environment.count, 1)
        XCTAssertTrue(base.calls[2].environment.keys.contains("ANTHROPIC_API_KEY"))
    }

    func testTheGitConfigOverridesResetTheHelperBeforeNamingGh() {
        let overrides = GitHubAccountEnvironment.overrides(token: "t")
        XCTAssertEqual(overrides["GIT_CONFIG_COUNT"], "2")
        XCTAssertEqual(overrides["GIT_CONFIG_KEY_0"], "credential.https://github.com.helper")
        XCTAssertEqual(overrides["GIT_CONFIG_VALUE_0"], "")
        XCTAssertEqual(overrides["GIT_CONFIG_KEY_1"], "credential.https://github.com.helper")
    }
}
