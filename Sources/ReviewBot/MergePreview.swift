import Foundation

/// What the pull request looks like **merged into its base branch**, rather than as its author
/// wrote it.
///
/// `gh pr diff` is a three-dot diff (merge-base..head), so every reviewer reads the pull request
/// against the commit it was cut from — never against where it will land. A branch that goes stale
/// mid-review can delete a symbol the base branch still calls, and nothing in the diff, the
/// worktree, or the thread says so: the deleted file is absent from the checkout, and the caller
/// that breaks was never touched by the pull request.
///
/// Conflicts alone are not the signal. The dangerous case carries **no conflict at all** — when one
/// side removes a `use` line and the other edits a different method of the same class, git
/// auto-merges them into code that no longer compiles. So this preview reports three overlaps, and
/// the quiet one matters most:
///
/// - `conflictingPaths` — git says these collide textually. Loud, and already caught at merge time.
/// - `bothChangedPaths` — both sides touched these since the merge base. This is where a silent
///   semantic conflict hides, and it is a superset of the conflicting paths.
/// - `deletedHerePaths` — the pull request deletes these and the base branch modified them. The
///   sharpest signal available: something on the base is still invested in a file being removed.
///
/// Paths alone would not be actionable. Reviewers hold Read/Grep/Glob over a worktree checked out
/// at the pull request's head, so they cannot open the base branch's version of anything — the very
/// evidence a merge finding rests on. `baseSideDiff` carries it inline: the base branch's own
/// changes, restricted to the overlapping paths. Restricting matters. On the pull request that
/// motivated this type the full base-side diff was 94 KB while the overlap was 6.5 KB, and only the
/// overlap is evidence.
struct MergePreview: Equatable {
    /// Bytes of base-side diff to inline. Past this the evidence stops being evidence and starts
    /// crowding out the pull request's own diff in the reviewer's context.
    static let baseSideDiffByteBudget = 60_000

    let baseRefName: String
    let behindCount: Int
    let conflictingPaths: [String]
    let bothChangedPaths: [String]
    let deletedHerePaths: [String]
    let baseSideDiff: String
    /// Paths whose base-side diff was dropped for the byte budget. Disclosed in the rendered file:
    /// a silently truncated evidence section reads as "nothing else changed there", which is the
    /// one conclusion it must never support.
    let omittedDiffPaths: [String]

    /// True when the pull request is current with its base and nothing overlaps — the common case,
    /// where the three-dot diff already tells the whole story and the preview adds nothing.
    var isClean: Bool {
        behindCount == 0
            && conflictingPaths.isEmpty
            && bothChangedPaths.isEmpty
            && deletedHerePaths.isEmpty
    }

    /// Conflicted paths from `git merge-tree --write-tree --name-only`.
    ///
    /// The output is a tree OID on the first line, then one conflicted path per line, then a blank
    /// line and human-readable merge messages. Anything after that blank line is prose about
    /// auto-merges, not a path, so parsing stops there.
    static func conflictPaths(fromMergeTree output: String) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop the tree OID; take paths until the blank line that ends the machine-readable section.
        return Array(lines.dropFirst().prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Truncates the base-side diff at a whole-file boundary, so what survives is always a set of
    /// complete `diff --git` sections rather than a hunk cut mid-context. Returns the kept text and
    /// every path left without evidence in it.
    ///
    /// A section larger than the whole budget is dropped rather than half-shown: a diff cut
    /// mid-hunk invites a confident finding about code whose surrounding context is missing, which
    /// is worse than no evidence plus an explicit note that there is none.
    ///
    /// The omission list is derived from the kept text in every case, not only when truncation
    /// happened, so a path is reported as unevidenced whatever the cause — over budget, or a diff
    /// that could not be produced at all.
    static func fitDiff(
        _ diff: String,
        paths: [String],
        budget: Int = baseSideDiffByteBudget
    ) -> (kept: String, omitted: [String]) {
        let text: String
        if diff.utf8.count <= budget {
            text = diff
        } else {
            // Split on the file-section marker, keeping it attached to each section that follows.
            let sections = diff.components(separatedBy: "\ndiff --git ")
                .enumerated()
                .map { $0.offset == 0 ? $0.element : "diff --git " + $0.element }

            var kept: [String] = []
            var used = 0
            for section in sections {
                let cost = section.utf8.count + 1
                guard used + cost <= budget else { break }
                kept.append(section)
                used += cost
            }
            text = kept.joined(separator: "\n")
        }
        // A path counts as kept only when its own `diff --git` header survived. Matching the bare
        // path anywhere in the text would call a path "kept" because some other file's diff merely
        // mentions it — in a comment, an import, a moved reference — and under-reporting an
        // omission is the one error this must not make: it would present missing evidence as clean.
        let omitted = paths.filter { !text.contains("diff --git a/\($0) ") }
        return (text, omitted)
    }

    /// Builds the preview from raw git output. Pure, so the parsing, set arithmetic, and truncation
    /// are testable without a repository — the engine only supplies the strings.
    ///
    /// `mergeTreeOutput` is `nil` when the merge-tree probe could not run at all (git older than
    /// 2.38, which has no `--write-tree`). The overlap sets come from plain `git diff --name-only`,
    /// which every git has, so a missing conflict probe degrades the preview rather than losing it.
    static func compose(
        baseRefName: String,
        behindCount: Int,
        mergeTreeOutput: String?,
        prChangedPaths: [String],
        baseChangedPaths: [String],
        prDeletedPaths: [String],
        baseSideDiff: String = ""
    ) -> MergePreview {
        let baseChanged = Set(baseChangedPaths)
        let prChanged = Set(prChangedPaths)
        // Sorted, not source-ordered: the reviewers read these as a checklist, and a stable order
        // keeps the same PR reviewed twice from reading as two different situations.
        let bothChanged = prChanged.intersection(baseChanged).sorted()
        let (kept, omitted) = fitDiff(baseSideDiff, paths: bothChanged)
        return MergePreview(
            baseRefName: baseRefName,
            behindCount: behindCount,
            conflictingPaths: mergeTreeOutput.map { conflictPaths(fromMergeTree: $0) } ?? [],
            bothChangedPaths: bothChanged,
            deletedHerePaths: Set(prDeletedPaths).intersection(baseChanged).sorted(),
            baseSideDiff: kept,
            omittedDiffPaths: omitted
        )
    }

    /// The Markdown written to `.review-bot-merge.md` for the reviewers to read.
    func render() -> String {
        guard !isClean else {
            return """
                # Merge preview

                This pull request is up to date with `\(baseRefName)`: no commits have landed on the
                base since it was cut, and nothing it touches was touched there. The diff you are
                reviewing is exactly what will land.
                """
        }

        var sections: [String] = [
            """
            # Merge preview

            `.review-bot-diff.patch` is a three-dot diff — the pull request against the commit it \
            was **cut from**, not against where it will **land**. `\(baseRefName)` has moved \
            \(behindCount) commit\(behindCount == 1 ? "" : "s") ahead since then. This file is the \
            difference, and it is the only place you can see it: your worktree is checked out at \
            the pull request's head, so nothing you Read or Grep reflects the base branch.
            """
        ]

        if !conflictingPaths.isEmpty {
            sections.append(
                """
                ## Conflicts with `\(baseRefName)`

                Merging as-is produces conflicts in:

                \(conflictingPaths.map { "- `\($0)`" }.joined(separator: "\n"))
                """
            )
        }

        if !deletedHerePaths.isEmpty {
            sections.append(
                """
                ## Deleted here, modified on `\(baseRefName)`

                \(deletedHerePaths.map { "- `\($0)`" }.joined(separator: "\n"))

                This pull request removes these files while the base branch was still changing them. \
                Check what on the base still depends on them — the checkout you are reading does not \
                contain these files, so a caller left behind cannot show up in any search you run \
                here.
                """
            )
        }

        if !bothChangedPaths.isEmpty {
            sections.append(
                """
                ## Changed on both sides

                \(bothChangedPaths.map { "- `\($0)`" }.joined(separator: "\n"))

                Both this pull request and `\(baseRefName)` changed these since the merge base. Paths \
                listed here but **not** under "Conflicts" deserve the most attention: git merges them \
                silently, so a semantic break — a removed import whose symbol is still called, a \
                renamed method the other side now invokes — lands with no conflict marker and no \
                failing merge.
                """
            )
        }

        if !baseSideDiff.isEmpty {
            sections.append(
                """
                ## What `\(baseRefName)` did to those paths

                The base branch's own changes since the merge base, restricted to the overlapping \
                paths above. This is your evidence: the pull request's diff cannot show it, and \
                neither can the worktree.

                ```diff
                \(baseSideDiff)
                ```
                """
            )
        }

        if !omittedDiffPaths.isEmpty {
            sections.append(
                """
                > **Evidence missing for some paths.** These are listed above without their \
                base-side changes shown, usually because the diff exceeded the \
                \(Self.baseSideDiffByteBudget / 1000) KB budget: \
                \(omittedDiffPaths.map { "`\($0)`" }.joined(separator: ", ")). Treat them as \
                unverified rather than as clean — the absence of evidence here is not evidence that \
                the base branch left them alone.
                """
            )
        }

        sections.append(
            """
            ## Scope

            A defect that appears only **after** this merges is in scope for this review and may be \
            `BLOCKING`, even though its `path:line` is not in `.review-bot-diff.patch` — the diff \
            cannot contain it by construction. This is a deliberate exception to the scope gate, and \
            it is narrow: it covers defects caused by the interaction between this pull request and \
            the base branch, nothing else.

            Report such a finding only when you can name the concrete breakage from the evidence \
            above — the symbol that goes undefined, the caller that survives, the contract that \
            stops holding. Staleness on its own is not a defect; being behind the base is normal and \
            reporting it as a finding is noise.
            """
        )

        return sections.joined(separator: "\n\n")
    }
}
