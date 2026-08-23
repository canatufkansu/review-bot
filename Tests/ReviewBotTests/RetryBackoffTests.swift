import Foundation
import XCTest
@testable import ReviewBot

final class RetryBackoffTests: XCTestCase {
    func testFirstRetryIsImmediateThenTheDelayDoubles() {
        // The poll interval is already the natural spacing, so the first retry adds
        // nothing; every failure after that doubles the extra wait.
        XCTAssertEqual(ReviewEngine.retryDelaySeconds(failures: 1, pollIntervalMinutes: 15), 0)
        XCTAssertEqual(ReviewEngine.retryDelaySeconds(failures: 2, pollIntervalMinutes: 15), 15 * 60)
        XCTAssertEqual(ReviewEngine.retryDelaySeconds(failures: 3, pollIntervalMinutes: 15), 45 * 60)
        XCTAssertEqual(ReviewEngine.retryDelaySeconds(failures: 4, pollIntervalMinutes: 15), 105 * 60)
    }

    func testDelayIsCappedAndHandlesDegenerateInput() {
        XCTAssertEqual(
            ReviewEngine.retryDelaySeconds(failures: 12, pollIntervalMinutes: 15),
            ReviewEngine.maximumRetryDelaySeconds
        )
        XCTAssertEqual(
            ReviewEngine.retryDelaySeconds(failures: 5_000, pollIntervalMinutes: 60),
            ReviewEngine.maximumRetryDelaySeconds
        )
        XCTAssertEqual(ReviewEngine.retryDelaySeconds(failures: 0, pollIntervalMinutes: 15), 0)
        XCTAssertEqual(ReviewEngine.retryDelaySeconds(failures: 2, pollIntervalMinutes: 0), 60)
    }

    func testAttemptStoreCountsFailuresAndClearsThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotAttemptTests-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let store = ReviewAttemptStore(paths: paths)
        XCTAssertNil(store.attempt(for: "acme/widget#42@head@marker"))
        XCTAssertEqual(store.recordFailure(for: "acme/widget#42@head@marker", at: now), 1)
        XCTAssertEqual(store.recordFailure(for: "acme/widget#42@head@marker", at: now), 2)

        // Reloading from disk keeps the count and the timestamp.
        let reloaded = ReviewAttemptStore(paths: paths)
        let attempt = try XCTUnwrap(reloaded.attempt(for: "acme/widget#42@head@marker"))
        XCTAssertEqual(attempt.failures, 2)
        XCTAssertEqual(attempt.lastAttempt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)

        reloaded.clear("acme/widget#42@head@marker", at: now)
        XCTAssertNil(ReviewAttemptStore(paths: paths).attempt(for: "acme/widget#42@head@marker"))
    }

    func testAttemptStoreDropsEntriesPastRetention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotAttemptTests-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReviewAttemptStore(paths: paths)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordFailure(for: "acme/widget#1@head@marker", at: old)
        // A later write prunes anything older than the retention window.
        store.recordFailure(for: "acme/widget#2@head@marker", at: old.addingTimeInterval(60 * 24 * 60 * 60))

        let reloaded = ReviewAttemptStore(paths: paths)
        XCTAssertNil(reloaded.attempt(for: "acme/widget#1@head@marker"))
        XCTAssertNotNil(reloaded.attempt(for: "acme/widget#2@head@marker"))
    }

    func testConfigurationDefaultsToABoundedFailureBudget() throws {
        XCTAssertEqual(ReviewBotConfiguration.default.maxFailedAttemptsPerReview, 5)

        // A config written before this setting existed adopts the bounded default…
        let legacy = Data(#"{"pollIntervalMinutes":15}"#.utf8)
        let migrated = try JSONDecoder().decode(ReviewBotConfiguration.self, from: legacy)
        XCTAssertEqual(migrated.maxFailedAttemptsPerReview, 5)

        // …while an explicit null means "retry indefinitely".
        let explicitNull = Data(#"{"maxFailedAttemptsPerReview":null}"#.utf8)
        let unlimited = try JSONDecoder().decode(ReviewBotConfiguration.self, from: explicitNull)
        XCTAssertNil(unlimited.maxFailedAttemptsPerReview)

        let clamped = Data(#"{"maxFailedAttemptsPerReview":0}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ReviewBotConfiguration.self, from: clamped).maxFailedAttemptsPerReview,
            1
        )

        // "Off" must survive a save/load cycle rather than reverting to the default.
        var configuration = ReviewBotConfiguration.default
        configuration.maxFailedAttemptsPerReview = nil
        let reloaded = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: try JSONEncoder().encode(configuration)
        )
        XCTAssertNil(reloaded.maxFailedAttemptsPerReview)
        XCTAssertEqual(reloaded, configuration)
    }
}
