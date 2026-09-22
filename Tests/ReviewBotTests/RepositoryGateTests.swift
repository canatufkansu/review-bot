import XCTest
@testable import ReviewBot

final class RepositoryGateTests: XCTestCase {
    func testHoldersOfTheSameKeyNeverOverlap() async {
        let gate = RepositoryGate()
        let observer = ConcurrencyObserver()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire("acme/widget")
                    await observer.enter()
                    // Suspend while holding the gate: the point of the gate is that a
                    // holder's `await` does not let another holder in.
                    try? await Task.sleep(for: .milliseconds(5))
                    await observer.leave()
                    await gate.release("acme/widget")
                }
            }
        }

        let peak = await observer.peak()
        let total = await observer.total()
        XCTAssertEqual(peak, 1, "Two reviews held the same repository's git lock at once")
        XCTAssertEqual(total, 8, "Every waiter should be handed the gate in turn")
    }

    func testDifferentKeysDoNotWaitOnEachOther() async {
        let gate = RepositoryGate()
        let observer = ConcurrencyObserver()

        await withTaskGroup(of: Void.self) { group in
            for repository in ["acme/widget", "acme/gadget", "acme/sprocket"] {
                group.addTask {
                    await gate.acquire(repository)
                    await observer.enter()
                    // Wait for the others to get in too. If a key blocked an unrelated
                    // key, this returns on the deadline and the peak stays below three.
                    await observer.waitForPeak(3)
                    await observer.leave()
                    await gate.release(repository)
                }
            }
        }

        let peak = await observer.peak()
        XCTAssertEqual(peak, 3, "Repositories share no clone, so their git steps should overlap")
    }

    func testTheGateIsReusableAfterEveryHolderHasLeft() async {
        let gate = RepositoryGate()

        await gate.acquire("acme/widget")
        await gate.release("acme/widget")
        // Would hang instead of returning if `release` left the key marked as held.
        await gate.acquire("acme/widget")
        await gate.release("acme/widget")
    }
}

/// Counts how many tasks are inside a section at once, and lets them wait for each
/// other up to a deadline — so "these ran in parallel" is asserted on an observed
/// peak rather than on timing luck, and "these did not" fails in a bounded time
/// instead of hanging the suite.
private actor ConcurrencyObserver {
    private var current = 0
    private var highest = 0
    private var entries = 0

    func enter() {
        current += 1
        entries += 1
        highest = max(highest, current)
    }

    func leave() {
        current -= 1
    }

    func peak() -> Int { highest }
    func total() -> Int { entries }

    /// Suspends until `count` tasks are inside the section, or ~1s has passed.
    func waitForPeak(_ count: Int, deadlineMilliseconds: Int = 1_000) async {
        var waited = 0
        while current < count, waited < deadlineMilliseconds {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
    }
}
