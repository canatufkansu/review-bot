import XCTest
@testable import ReviewBot

final class MergePreviewTests: XCTestCase {
    /// Real output shape from `git merge-tree --write-tree --name-only`: a tree OID, the conflicted
    /// paths, a blank line, then prose. Only the paths are paths.
    private let mergeTreeOutput = """
        33f53bc068753a97146804adf82fe2e7776427e4
        app/Http/Controllers/V1/BuyIntent/Concerns/MapsLocationScopes.php
        app/Http/Controllers/V1/BuyIntent/MatchCountsController.php

        CONFLICT (modify/delete): app/Http/Controllers/V1/BuyIntent/Concerns/MapsLocationScopes.php deleted in 0a4ef05b and modified in 711e5a3f.
        Auto-merging app/Http/Controllers/V1/BuyIntent/ListMatchesController.php
        """

    func testParsesConflictPathsAndStopsBeforeTheProse() {
        XCTAssertEqual(
            MergePreview.conflictPaths(fromMergeTree: mergeTreeOutput),
            [
                "app/Http/Controllers/V1/BuyIntent/Concerns/MapsLocationScopes.php",
                "app/Http/Controllers/V1/BuyIntent/MatchCountsController.php",
            ]
        )
    }

    func testACleanMergeHasNoConflictPaths() {
        XCTAssertEqual(
            MergePreview.conflictPaths(fromMergeTree: "33f53bc068753a97146804adf82fe2e7776427e4\n"),
            []
        )
    }

    /// The defect this whole type exists for: a path both sides changed that git merges *silently*.
    /// It must surface even though `merge-tree` reports no conflict on it.
    func testSurfacesASilentlyMergingPathThatConflictDetectionMisses() {
        let preview = MergePreview.compose(
            baseRefName: "develop",
            behindCount: 2,
            mergeTreeOutput: mergeTreeOutput,
            prChangedPaths: [
                "app/Http/Controllers/V1/BuyIntent/Concerns/MapsLocationScopes.php",
                "app/Http/Controllers/V1/BuyIntent/ListMatchesController.php",
                "app/Http/Controllers/V1/BuyIntent/MatchCountsController.php",
                "src/Ai/Handlers/AskAIHandler.php",
            ],
            baseChangedPaths: [
                "app/Http/Controllers/V1/BuyIntent/Concerns/MapsLocationScopes.php",
                "app/Http/Controllers/V1/BuyIntent/ListMatchesController.php",
                "app/Http/Controllers/V1/BuyIntent/MatchCountsController.php",
                "docs/unrelated.md",
            ],
            prDeletedPaths: ["app/Http/Controllers/V1/BuyIntent/Concerns/MapsLocationScopes.php"]
        )

        XCTAssertFalse(preview.isClean)
        XCTAssertTrue(
            preview.bothChangedPaths
                .contains("app/Http/Controllers/V1/BuyIntent/ListMatchesController.php"),
            "the silently auto-merging path is the one finding that depends on this preview"
        )
        XCTAssertFalse(
            preview.conflictingPaths
                .contains("app/Http/Controllers/V1/BuyIntent/ListMatchesController.php"),
            "and conflict detection alone does not report it"
        )
        // Touched by only one side each, so neither is an overlap.
        XCTAssertFalse(preview.bothChangedPaths.contains("src/Ai/Handlers/AskAIHandler.php"))
        XCTAssertFalse(preview.bothChangedPaths.contains("docs/unrelated.md"))
        XCTAssertEqual(
            preview.deletedHerePaths,
            ["app/Http/Controllers/V1/BuyIntent/Concerns/MapsLocationScopes.php"]
        )
    }

    /// A file the PR deletes that the base never touched is not interesting — the base has no stake
    /// in it, so it must not be reported as a merge risk.
    func testDeletionTheBaseNeverTouchedIsNotReported() {
        let preview = MergePreview.compose(
            baseRefName: "main",
            behindCount: 3,
            mergeTreeOutput: nil,
            prChangedPaths: ["a.swift", "gone.swift"],
            baseChangedPaths: ["a.swift"],
            prDeletedPaths: ["gone.swift"]
        )
        XCTAssertEqual(preview.deletedHerePaths, [])
        XCTAssertEqual(preview.bothChangedPaths, ["a.swift"])
    }

    /// Git older than 2.38 has no `--write-tree`. The overlap sets come from plain `git diff`, so
    /// the preview must degrade rather than vanish.
    func testMissingMergeTreeProbeStillYieldsOverlap() {
        let preview = MergePreview.compose(
            baseRefName: "main",
            behindCount: 1,
            mergeTreeOutput: nil,
            prChangedPaths: ["shared.swift"],
            baseChangedPaths: ["shared.swift"],
            prDeletedPaths: []
        )
        XCTAssertEqual(preview.conflictingPaths, [])
        XCTAssertEqual(preview.bothChangedPaths, ["shared.swift"])
        XCTAssertFalse(preview.isClean)
        XCTAssertTrue(preview.render().contains("Changed on both sides"))
    }

    func testUpToDateBranchRendersNothingToActOn() {
        let preview = MergePreview.compose(
            baseRefName: "main",
            behindCount: 0,
            mergeTreeOutput: nil,
            prChangedPaths: ["a.swift"],
            baseChangedPaths: [],
            prDeletedPaths: []
        )
        XCTAssertTrue(preview.isClean)
        XCTAssertTrue(preview.render().contains("exactly what will land"))
    }

    func testRenderCarriesTheEvidenceAndTheScopeException() {
        let preview = MergePreview.compose(
            baseRefName: "develop",
            behindCount: 2,
            mergeTreeOutput: mergeTreeOutput,
            prChangedPaths: ["shared.php"],
            baseChangedPaths: ["shared.php"],
            prDeletedPaths: [],
            baseSideDiff: "diff --git a/shared.php b/shared.php\n+    public function scopedLocations() {}"
        )
        let rendered = preview.render()
        XCTAssertTrue(rendered.contains("scopedLocations"), "the base-side change is the evidence")
        XCTAssertTrue(rendered.contains("`develop` has moved 2 commits ahead"))
        XCTAssertTrue(rendered.contains("BLOCKING"), "the scope exception must be stated")
        XCTAssertFalse(rendered.contains("Evidence missing"))
    }

    // MARK: - Truncation

    private func diffSection(path: String, padding: Int) -> String {
        "diff --git a/\(path) b/\(path)\n" + String(repeating: "+x\n", count: padding)
    }

    func testOversizedEvidenceIsTruncatedAtAFileBoundaryAndDisclosed() {
        // ~45 KB fits inside the 60 KB budget; the ~24 KB that follows does not.
        let big = diffSection(path: "big.swift", padding: 15_000)
        let small = diffSection(path: "small.swift", padding: 8_000)
        let (kept, omitted) = MergePreview.fitDiff(
            big + "\n" + small,
            paths: ["big.swift", "small.swift"]
        )

        XCTAssertTrue(kept.utf8.count <= MergePreview.baseSideDiffByteBudget)
        XCTAssertEqual(omitted, ["small.swift"], "the dropped path must be named, not silently lost")
        // What survives is a whole section, never a hunk cut mid-context.
        XCTAssertTrue(kept.hasPrefix("diff --git a/big.swift"))
        XCTAssertFalse(kept.contains("diff --git a/small.swift"))
    }

    /// A single section bigger than the whole budget is dropped, not half-shown: a diff cut
    /// mid-hunk invites a confident finding about code whose context is missing.
    func testLoneOversizedSectionIsDroppedRatherThanHalfShown() {
        let (kept, omitted) = MergePreview.fitDiff(
            diffSection(path: "huge.swift", padding: 30_000),
            paths: ["huge.swift"]
        )
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(omitted, ["huge.swift"])
    }

    /// Omission is decided by whether a path's own `diff --git` header survived. Matching the bare
    /// path anywhere would call a path "evidenced" because another file's diff merely mentions it,
    /// and under-reporting an omission presents missing evidence as clean.
    func testPathMerelyMentionedInAnotherDiffCountsAsOmitted() {
        let diff = "diff --git a/keeper.swift b/keeper.swift\n+// see also other.swift\n"
        let (kept, omitted) = MergePreview.fitDiff(diff, paths: ["keeper.swift", "other.swift"])
        XCTAssertEqual(kept, diff)
        XCTAssertEqual(omitted, ["other.swift"])
    }

    func testMissingEvidenceIsDisclosedInTheRenderedFile() {
        let preview = MergePreview.compose(
            baseRefName: "develop",
            behindCount: 1,
            mergeTreeOutput: nil,
            prChangedPaths: ["big.swift", "small.swift"],
            baseChangedPaths: ["big.swift", "small.swift"],
            prDeletedPaths: [],
            baseSideDiff: diffSection(path: "big.swift", padding: 15_000)
                + "\n" + diffSection(path: "small.swift", padding: 8_000)
        )
        let rendered = preview.render()
        XCTAssertTrue(rendered.contains("Evidence missing for some paths"))
        XCTAssertTrue(rendered.contains("`small.swift`"))
        XCTAssertTrue(
            rendered.contains("unverified rather than as clean"),
            "a truncated section must not read as an all-clear"
        )
    }

    func testEvidenceUnderBudgetIsKeptWhole() {
        let diff = diffSection(path: "a.swift", padding: 5) + "\n" + diffSection(path: "b.swift", padding: 5)
        let (kept, omitted) = MergePreview.fitDiff(diff, paths: ["a.swift", "b.swift"])
        XCTAssertEqual(kept, diff)
        XCTAssertEqual(omitted, [])
    }
}
