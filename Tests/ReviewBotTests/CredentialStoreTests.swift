import XCTest
@testable import ReviewBot

/// The credential rules that hold on every platform: the reviewer surface both stores derive
/// their answers from, the shared environment override, and the in-memory test double.
final class CredentialStoreTests: XCTestCase {
    /// Every reviewer needs an inbound variable, including ones with no CLI — this is the part
    /// of the "adding a reviewer" checklist a new case is most likely to miss. The exact names
    /// are asserted in `ConfigurationAndPromptTests`; what matters here is that no two reviewers
    /// can be credentialed from the same variable and none is silently blank.
    func testEveryReviewerHasADistinctOverrideVariable() {
        let variables = ReviewerName.allCases.map(\.apiKeyOverrideEnvironmentVariable)
        XCTAssertFalse(variables.contains { $0.isEmpty })
        XCTAssertEqual(Set(variables).count, variables.count)
    }

    /// `apiKeyOverrideEnvironmentVariable` is total, so opencode names one too — but opencode is
    /// credentialed through its own config directory and has no outbound key variable, so there
    /// is nowhere for a resolved key to go. Answering with one anyway would make the settings
    /// panel report a key as "in effect" for a reviewer that never sees it.
    func testAKeyIsNotResolvedForAReviewerThatCannotBeHandedOne() {
        let environment = [
            "OPENCODE_API_KEY": "sk-opencode",
            "ANTHROPIC_API_KEY": "sk-anthropic",
        ]

        XCTAssertNil(EnvironmentCredentialOverride.apiKey(for: .opencode, in: environment))
        // …and the refusal is specific to opencode, not a blanket one.
        XCTAssertEqual(
            EnvironmentCredentialOverride.apiKey(for: .claude, in: environment),
            "sk-anthropic"
        )
    }

    /// The test double deliberately carries no such guard: it returns exactly what a test handed
    /// it, so a mis-wired engine fails loudly instead of being quietly papered over.
    func testTheInMemoryStoreAnswersForWhateverATestGivesIt() {
        let store = InMemoryCredentialStore(keys: [.opencode: "sk-opencode"])
        XCTAssertEqual(store.apiKey(for: .opencode), "sk-opencode")
    }

    /// The outbound variable is handed to a CLI child; the inbound one is read by Review Bot.
    /// For the CLI reviewers they must name the same variable, or a key saved in the app would
    /// be read from one name and forwarded under another.
    func testOutboundAndInboundVariablesAgreeForCLIReviewers() {
        for reviewer in ReviewerName.allCases {
            guard let outbound = reviewer.apiKeyEnvironmentVariable else { continue }
            XCTAssertEqual(outbound, reviewer.apiKeyOverrideEnvironmentVariable)
        }
    }

    func testInMemoryStoreRemovesKeyWhenSetToBlank() throws {
        let store = InMemoryCredentialStore(keys: [.deepseek: "sk-existing"])
        try store.setAPIKey("   ", for: .deepseek)
        XCTAssertNil(store.apiKey(for: .deepseek))
    }
}
