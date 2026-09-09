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

        func run(_ executable: String, arguments: [String], currentDirectory: URL?, timeout: Int) async throws -> CommandResult {
            try await run(executable, arguments: arguments, currentDirectory: currentDirectory, environment: [:], timeout: timeout)
        }

        func run(_ executable: String, arguments: [String], currentDirectory: URL?, environment: EnvironmentOverrides, timeout: Int) async throws -> CommandResult {
            calls.append((executable, environment))
            return CommandResult(command: executable, exitCode: 0, stdout: "", stderr: "")
        }
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
