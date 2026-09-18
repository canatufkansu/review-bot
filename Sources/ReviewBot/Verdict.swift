import Foundation

enum VerdictParser {
    /// The machine-readable verdict line a reviewer must end with. Shared by the
    /// parser and `InjectionGuard` (which scans untrusted thread/diff text for
    /// planted lines that would match).
    static let verdictLineRegex = #"(?im)^\s*VERDICT:\s*(BLOCKING|SHOULD_FIX|NITS_ONLY|CLEAN)\s*$"#

    static func parse(_ output: String) -> ReviewVerdict? {
        guard let regex = try? NSRegularExpression(pattern: verdictLineRegex),
              let match = regex.matches(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ).last,
              let range = Range(match.range(at: 1), in: output)
        else {
            return nil
        }

        return ReviewVerdict(rawValue: String(output[range]).uppercased())
    }

    static func bodyWithoutTrailer(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                parse(String(line)) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DecisionEvaluator {
    static func evaluate(_ results: [ReviewerResult], policy: DecisionPolicy) -> ReviewDecision {
        let parsed = results.compactMap(\.verdict)
        let actions = parsed.map { policy.action(for: $0) }
        let worstAction = actions.max(by: { $0.rank < $1.rank })

        // Decide on whoever finished, and honour the strictest configured action among them
        // (`.comment` if any level is set to "leave it to me", otherwise `.approve`). A reviewer
        // that failed contributes nothing rather than pinning the decision to neutral: an outage
        // in one CLI would otherwise mean the other reviewer's findings never gate anything.
        // This can still come back `.approve` from a partial panel — that is fine for *this*
        // function, which only decides on survivors. `withholdingApprovalFromPartialPanel` below
        // is the actual cap the engine applies afterward, since an approval is the one decision
        // that needs the whole panel to have weighed in.
        //
        // `worstAction` is nil exactly when no reviewer parsed a verdict, which is the one case
        // with nothing to decide on. The engine declines to post at all there; `.comment` is the
        // safe answer for any other caller.
        return worstAction ?? .comment
    }

    /// Caps an approval reached by an incomplete panel. An approval is the one decision that
    /// needs the whole panel: a partial panel may still gate — a `SHOULD_FIX`+ finding from a
    /// reviewer that did finish is still a real finding, so `.requestChanges` and `.comment`
    /// pass through unchanged — but it may not clear a pull request when another enabled
    /// reviewer never weighed in. Waiting for a later poll does not help when the missing
    /// reviewer failed for a terminal reason, such as an exhausted weekly quota: the failure
    /// budget would run out first and nothing would ever be posted. So the survivors' findings
    /// post as a neutral comment instead, naming who is missing and why (`aggregateReview`).
    static func withholdingApprovalFromPartialPanel(
        _ decision: ReviewDecision,
        results: [ReviewerResult]
    ) -> ReviewDecision {
        guard decision == .approve, results.contains(where: { $0.verdict == nil }) else {
            return decision
        }
        return .comment
    }

    /// True when two or more reviewers parsed a verdict but land on opposite sides of the
    /// policy's request-changes boundary — at least one action is `.requestChanges` while at
    /// least one is not. A lone reviewer's false blocker is the main way strictest-wins
    /// mis-gates a correct PR, so this disagreement is the signal to reconcile before deciding.
    static func gateDisagreement(_ results: [ReviewerResult], policy: DecisionPolicy) -> Bool {
        let actions = results.compactMap(\.verdict).map { policy.action(for: $0) }
        guard actions.count >= 2 else { return false }
        return actions.contains { $0 == .requestChanges } && actions.contains { $0 != .requestChanges }
    }

    /// Maps a single reconciled verdict to the GitHub action under the active policy.
    static func decision(for verdict: ReviewVerdict, policy: DecisionPolicy) -> ReviewDecision {
        policy.action(for: verdict)
    }
}
