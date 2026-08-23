import Foundation

/// What to do with a review request that has failed before.
enum RetryDecision: Equatable {
    /// Try it again now.
    case run
    /// Still inside the backoff window; `remaining` is how long is left of it.
    case backOff(remaining: TimeInterval)
    /// Out of attempts. Only a new commit, a re-request, or a manual run revives it.
    case exhausted(failures: Int)
}

/// Decides when a review request that never posted may be tried again.
///
/// A review that fails leaves its dedup key unrecorded so the next poll retries it.
/// Without a policy that retry is unbounded: a permanently broken reviewer re-runs
/// the whole pipeline on every poll forever. This is the pure decision half of that
/// bound — `ReviewEngine` supplies the stored attempt and the clock.
enum RetryPolicy {
    /// Ceiling on the backoff: a request stuck behind an outage still gets a few
    /// attempts a day rather than drifting into never.
    static let maximumDelay: TimeInterval = 4 * 60 * 60

    static func decide(
        attempt: ReviewAttempt?,
        budget: FailureBudget,
        pollIntervalMinutes: Int,
        now: Date
    ) -> RetryDecision {
        guard let attempt, attempt.failures > 0 else { return .run }
        if let limit = budget.limit, attempt.failures >= limit {
            return .exhausted(failures: attempt.failures)
        }
        let remaining = delay(
            afterFailures: attempt.failures,
            pollIntervalMinutes: pollIntervalMinutes
        ) - now.timeIntervalSince(attempt.lastAttempt)
        return remaining > 0 ? .backOff(remaining: remaining) : .run
    }

    /// How long to wait after `failures` consecutive failed attempts before trying the
    /// same review request again. The first retry is immediate — the poll interval is
    /// already the natural spacing — and each failure after that doubles the gap added
    /// on top of it: 0, 1×, 3×, 7×, 15× the poll interval, capped at `maximumDelay`.
    /// At the 15-minute default that is an immediate retry, then 15m, 45m and 1h45m.
    static func delay(afterFailures failures: Int, pollIntervalMinutes: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let interval = TimeInterval(max(1, pollIntervalMinutes) * 60)
        // 2^30 is far past the cap; clamping the exponent keeps the shift in range.
        let multiplier = TimeInterval((1 << min(failures - 1, 30)) - 1)
        return min(interval * multiplier, maximumDelay)
    }

    /// The trailing sentence on a failure entry: what happens to this request next.
    static func note(
        failures: Int,
        budget: FailureBudget,
        pollIntervalMinutes: Int
    ) -> String {
        let attempt = budget.limit.map { "Attempt \(failures) of \($0)" } ?? "Attempt \(failures)"
        if let limit = budget.limit, failures >= limit {
            return attempt + " — giving up on this request; a new commit, a re-request, or Run now starts over."
        }
        let wait = delay(afterFailures: failures, pollIntervalMinutes: pollIntervalMinutes)
        return wait > 0
            ? attempt + " — retrying in about \(durationDescription(wait))."
            : attempt + " — retrying on the next check."
    }

    static func durationDescription(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        return String(format: "%.1f hours", Double(minutes) / 60)
    }
}
