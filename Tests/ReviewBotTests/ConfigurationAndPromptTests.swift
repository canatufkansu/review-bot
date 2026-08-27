import XCTest
@testable import ReviewBot

final class ConfigurationAndPromptTests: XCTestCase {
    func testOlderConfigurationDefaultsToActiveFifteenMinutePolling() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": "Focus on migrations"
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(configuration.pollIntervalMinutes, 15)
        XCTAssertFalse(configuration.isPaused)
        XCTAssertEqual(configuration.customPrompt, "Focus on migrations")
        XCTAssertEqual(configuration.reviewScope, .fullPullRequest)
        XCTAssertNil(configuration.maxReviewRoundsPerPR)
        // opencode is new, opt-in, and defaults to the free flash model at max effort.
        XCTAssertFalse(configuration.opencode.enabled)
        XCTAssertEqual(configuration.opencode.model, "opencode/deepseek-v4-flash-free")
        XCTAssertEqual(configuration.opencode.effort, .max)
    }

    func testOpencodeConfigurationDecodesAndClampsEffortToMax() throws {
        let json = #"""
        {
          "repositories": [],
          "opencode": { "enabled": true, "model": "opencode/deepseek-v4-flash-free", "effort": "xhigh" }
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        // opencode's CLI accepts low/medium/high/max, so xhigh falls back to max.
        XCTAssertTrue(configuration.opencode.enabled)
        XCTAssertEqual(configuration.opencode.effort, .max)
    }

    func testMaxReviewRoundsDecodesAndClampsToAtLeastOne() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": "",
          "maxReviewRoundsPerPR": 0
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        // 0 is meaningless as a cap; it is clamped up to 1.
        XCTAssertEqual(configuration.maxReviewRoundsPerPR, 1)
    }

    func testReviewScopeDecodesWhenPresent() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": "",
          "reviewScope": "incremental"
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(configuration.reviewScope, .incremental)
    }

    func testLastReviewedStoreRoundTripsHeadPerPullRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotLastReviewed-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()

        let store = LastReviewedStore(paths: paths)
        XCTAssertNil(store.head(for: "acme/widget#42"))

        store.record("acme/widget#42", head: "deadbeef")
        XCTAssertEqual(store.head(for: "acme/widget#42"), "deadbeef")

        // A fresh store reloads persisted heads from disk.
        let reloaded = LastReviewedStore(paths: paths)
        XCTAssertEqual(reloaded.head(for: "acme/widget#42"), "deadbeef")
        XCTAssertNil(reloaded.head(for: "acme/widget#99"))
    }

    func testFailureBudgetDecodesWithABoundedDefault() throws {
        XCTAssertEqual(ReviewBotConfiguration.default.failureBudget, .attempts(5))

        // A config written before the setting existed adopts the bounded default…
        let legacy = Data(#"{"pollIntervalMinutes":15}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ReviewBotConfiguration.self, from: legacy).failureBudget,
            .attempts(5)
        )

        // …while zero means the user turned the budget off, and survives a save.
        let off = Data(#"{"failureBudget":0}"#.utf8)
        let unlimited = try JSONDecoder().decode(ReviewBotConfiguration.self, from: off)
        XCTAssertEqual(unlimited.failureBudget, .unlimited)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ReviewBotConfiguration.self,
                from: try JSONEncoder().encode(unlimited)
            ),
            unlimited
        )

        XCTAssertEqual(FailureBudget(limit: 0), .attempts(1))
        XCTAssertEqual(FailureBudget(limit: nil), .unlimited)
    }

    func testReviewAttemptStoreCountsFailuresAndClearsThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotAttempts-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()

        let now = Date()
        let store = ReviewAttemptStore(paths: paths, now: now)
        XCTAssertNil(store.attempt(for: "acme/widget#42@head@marker"))
        XCTAssertEqual(store.recordFailure(for: "acme/widget#42@head@marker", at: now), 1)
        XCTAssertEqual(store.recordFailure(for: "acme/widget#42@head@marker", at: now), 2)

        // A fresh store reloads the count and the timestamp from disk.
        let reloaded = ReviewAttemptStore(paths: paths, now: now)
        let attempt = try XCTUnwrap(reloaded.attempt(for: "acme/widget#42@head@marker"))
        XCTAssertEqual(attempt.failures, 2)
        XCTAssertEqual(attempt.lastAttempt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)

        reloaded.clear("acme/widget#42@head@marker", at: now)
        XCTAssertNil(ReviewAttemptStore(paths: paths, now: now).attempt(for: "acme/widget#42@head@marker"))
    }

    func testReviewAttemptStoreDropsEntriesPastRetention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotAttempts-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ReviewAttemptStore(paths: paths, now: old)
        store.recordFailure(for: "acme/widget#1@head@marker", at: old)

        // Loading past the retention window forgets the stale entry.
        let reloaded = ReviewAttemptStore(
            paths: paths,
            now: old.addingTimeInterval(ReviewAttemptStore.retention + 60)
        )
        XCTAssertNil(reloaded.attempt(for: "acme/widget#1@head@marker"))
    }

    func testRepositoryRulesAndCustomizationAreAddedToPrompt() {
        let prompt = DefaultPrompt.combined(
            with: "Run the project's formatter.",
            repositoryRules: "Treat database rollbacks as Blocking."
        )

        XCTAssertTrue(prompt.contains("Developer-specific review instructions"))
        XCTAssertTrue(prompt.contains("Run the project's formatter."))
        XCTAssertTrue(prompt.contains("Mandatory repository review rules"))
        XCTAssertTrue(prompt.contains("Treat database rollbacks as Blocking."))
        XCTAssertTrue(prompt.hasSuffix("--- END REVIEW.md ---"))
    }

    func testReconciliationMakesADowngradeJustifyItself() {
        let prompt = DefaultPrompt.reconciliation(reviews: [
            (reviewer: "Claude", body: "## Findings\nShould-fix: the count is wrong.", verdict: "SHOULD_FIX"),
            (reviewer: "Codex", body: "## Findings\nNone.", verdict: "CLEAN"),
        ])

        // Both reviews reach the adjudicator verbatim, tagged with who said what.
        XCTAssertTrue(prompt.contains("--- BEGIN Claude REVIEW (verdict: SHOULD_FIX) ---"))
        XCTAssertTrue(prompt.contains("--- BEGIN Codex REVIEW (verdict: CLEAN) ---"))
        XCTAssertTrue(prompt.contains("the count is wrong."))

        // A finding that survives substantiation and scope can still be reduced, but only
        // by naming what it actually costs — "polish" is the conclusion, not the argument.
        XCTAssertTrue(prompt.contains("Severity moves in both directions"))
        XCTAssertTrue(prompt.contains("is not a justification on its own"))
        XCTAssertTrue(prompt.contains("the finding stands at the severity it was given"))
        // And the adjudicator is not confined to loosening.
        XCTAssertTrue(prompt.contains("warrants a *higher* severity"))

        XCTAssertTrue(prompt.hasSuffix("VERDICT: <BLOCKING | SHOULD_FIX | NITS_ONLY | CLEAN>"))
    }
}
