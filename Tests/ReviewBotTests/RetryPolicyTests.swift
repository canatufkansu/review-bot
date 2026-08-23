import Foundation
import XCTest
@testable import ReviewBot

final class RetryPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    func testFirstRetryIsImmediateThenTheAddedGapDoubles() {
        // The poll interval is already the natural spacing, so the first retry adds
        // nothing; every failure after that doubles the gap added on top of it.
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 1, pollIntervalMinutes: 15), 0)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 2, pollIntervalMinutes: 15), 15 * 60)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 3, pollIntervalMinutes: 15), 45 * 60)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 4, pollIntervalMinutes: 15), 105 * 60)
    }

    func testDelayIsCappedAndHandlesDegenerateInput() {
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 12, pollIntervalMinutes: 15), RetryPolicy.maximumDelay)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 5_000, pollIntervalMinutes: 60), RetryPolicy.maximumDelay)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 0, pollIntervalMinutes: 15), 0)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 2, pollIntervalMinutes: 0), 60)
    }

    func testAFreshRequestRuns() {
        XCTAssertEqual(
            RetryPolicy.decide(attempt: nil, budget: .attempts(5), pollIntervalMinutes: 15, now: start),
            .run
        )
    }

    func testARequestInsideItsWindowBacksOffAndRunsOnceItElapses() {
        let attempt = ReviewAttempt(failures: 2, lastAttempt: start)

        XCTAssertEqual(
            RetryPolicy.decide(
                attempt: attempt,
                budget: .attempts(5),
                pollIntervalMinutes: 15,
                now: start.addingTimeInterval(14 * 60)
            ),
            .backOff(remaining: 60)
        )
        XCTAssertEqual(
            RetryPolicy.decide(
                attempt: attempt,
                budget: .attempts(5),
                pollIntervalMinutes: 15,
                now: start.addingTimeInterval(15 * 60)
            ),
            .run
        )
    }

    func testTheBudgetOutranksTheWindowAndUnlimitedNeverExhausts() {
        let attempt = ReviewAttempt(failures: 5, lastAttempt: start)
        let long = start.addingTimeInterval(30 * 24 * 60 * 60)

        XCTAssertEqual(
            RetryPolicy.decide(attempt: attempt, budget: .attempts(5), pollIntervalMinutes: 15, now: start),
            .exhausted(failures: 5)
        )
        XCTAssertEqual(
            RetryPolicy.decide(attempt: attempt, budget: .unlimited, pollIntervalMinutes: 15, now: long),
            .run
        )
    }

    func testTheFailureNoteSaysWhatHappensNext() {
        XCTAssertTrue(
            RetryPolicy.note(failures: 1, budget: .attempts(5), pollIntervalMinutes: 15)
                .hasPrefix("Attempt 1 of 5 — retrying on the next check")
        )
        XCTAssertEqual(
            RetryPolicy.note(failures: 2, budget: .attempts(5), pollIntervalMinutes: 15),
            "Attempt 2 of 5 — retrying in about 15 minutes."
        )
        XCTAssertTrue(
            RetryPolicy.note(failures: 5, budget: .attempts(5), pollIntervalMinutes: 15)
                .contains("giving up")
        )
        XCTAssertTrue(
            RetryPolicy.note(failures: 9, budget: .unlimited, pollIntervalMinutes: 15)
                .hasPrefix("Attempt 9 — retrying in about")
        )
    }
}
