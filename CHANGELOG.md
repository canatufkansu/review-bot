# Changelog

All notable changes to Review Bot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each tagged release publishes the notes from its matching version section below, so
keep `## [Unreleased]

## [0.1.11] - 2026-08-24

### Added

- **Bounded retries for reviews that never post.** A review request whose reviewers fail (or return no verdict), or whose post GitHub rejects, is still retried — but attempts are now counted, spaced by a widening backoff (the first retry stays immediate, then the added gap doubles each time — 15m, 45m, 1h45m at the default poll interval, capped at 4 hours), and abandoned after a configurable budget. A new **Failure budget** box on the Reviewers tab sets that budget (default 5 attempts, or off for the previous unbounded behavior). Previously a permanently broken reviewer — a missing CLI, a bad model name, expired auth — re-ran the whole pipeline (fetch, worktree, full diff, every reviewer at up to 900s) on *every* poll forever and flooded the history with failures. A new commit or re-request starts the budget over, and **Run now** ignores both the backoff and the budget — so fixing the cause and clicking it resumes abandoned requests. While any request is paused this way, the status line says so instead of reporting a quiet "Watching 1 repository".
- Failure entries in history now say which attempt failed and what happens next ("Attempt 2 of 5 — retrying in about 15 minutes.").

### Changed

- **A reviewer that fails is run again within the same review** instead of discarding the whole review and waiting out a poll interval. The worktree, diff and thread are already prepared, so the retry costs one CLI invocation rather than the entire pipeline, and the other reviewers' work is not thrown away. Timeouts are not retried in place — re-running a hung CLI would just spend its 900s again — and are left to the poll-level backoff.
- The re-review limit caption now states that it counts reviews that were actually posted; failed attempts are governed by the new failure budget instead.

### Fixed

- **A failed `gh` timeline lookup no longer swallows a re-request** ([#6](https://github.com/melihucar/review-bot/issues/6)). The marker lookup fell back to the pull request's head commit whenever the command failed — and that key is usually one an earlier review already recorded, so a rate limit or a network blip turned a genuine re-request at the same commit into a silent skip: no review, no history entry, no log line. A failed lookup is now reported as a failure and retried on the next poll; the fallback stays for the honest case of a timeline with no `review_requested` event.
- Pull requests that cannot be inspected (metadata or timeline) are now bounded by the same failure budget and backoff as failing reviews, so a renamed repository or a token that lost access no longer posts a failure entry on every poll forever.

## [0.1.9] - 2026-08-18

### Changed

- **Prompt-injection hardening.** Pull-request threads are now treated as untrusted input end to end: reviewers are told explicitly that thread content (including planted `VERDICT:` lines) is data, never instructions; and before the bot may post an approval, deterministic checks verify that (a) no `VERDICT:` line was planted in the thread or diff, and (b) no reviewer's own prose contradicts its verdict (a permissive verdict that describes a merge blocker is not trusted). A flagged approval posts as a neutral comment with a disclosure instead, so the worst outcome of an injected thread is a comment, never an auto-approval. The Reviewers tab also warns when a small/experimental model is selected, since those measurably degrade under adversarial thread content.
- CI and release workflows now run on the Node 24 action runtime: `actions/checkout@v5` and `softprops/action-gh-release@v3` (both actions previously used the deprecated Node 20 runtime).

## [0.1.8] - 2026-08-17

### Added

- **opencode as a third reviewer** (Reviewers tab). Off by default; when enabled it runs `opencode run` in the worktree under a dedicated read-only agent — every tool except Read/Grep/Glob is denied, project `opencode.json` and `.opencode` files shipped in the pull request cannot override that, and plugins are disabled (`--pure`). The default model is `opencode/deepseek-v4-flash-free` at **max** reasoning effort, since the model is free. It participates in the same parallel run, strictest-verdict aggregation, and reconciliation path as Claude and Codex.

### Changed

- The default Claude reviewer is now `claude-opus-5` at **high** effort (was `claude-opus-4-8` at max). Existing configurations keep the model and effort they already have; only fresh installs and out-of-range effort values pick up the new default.

## [0.1.7] - 2026-07-20

### Fixed

- CLIs installed through a version manager (nvm, mise, volta, fnm, asdf) are now found when the app is launched from Finder or at login. Such an app inherits launchd's minimal `PATH`, which excluded those install dirs, so `claude`/`codex` showed as "not found" and no reviews could run ([#1](https://github.com/melihucar/review-bot/issues/1)). `ProcessRunner` now probes the login+interactive shell for its real `PATH` once at startup (behind a sentinel marker and a `perl alarm` timeout so a chatty or hanging rc file can't corrupt or stall it), prepends it, and keeps the previous fixed directory list as a fallback.

## [0.1.6] - 2026-07-20

### Added

- A **re-review limit** setting (Reviewers tab): cap how many times a single pull request is reviewed across new commits and re-requests. Set an integer limit or leave it unlimited (default). Once a PR reaches the limit, further commits and re-requests on it are skipped.

## [0.1.5] - 2026-07-18

### Added

- A **review scope** setting (Reviewers tab): choose whether reviewers see the **whole PR** every time (default) or **only the new changes** since the last posted review. Incremental mode diffs the current head against the commit last reviewed, so reviewers focus on new work and don't re-flag already-reviewed code; it falls back to the whole PR on the first review, on a re-request with no new commits, or when the prior commit is no longer available locally.

## [0.1.4] - 2026-07-18

### Added

- A configurable **decision policy** (new "Decisions" settings tab). For each reviewer severity — Should-fix, Nits only, Clean — you choose whether Review Bot **Approves**, **Leaves it to you** (posts a neutral comment), or **Requests changes**. `BLOCKING` always requests changes and is locked. Defaults match prior behavior, so existing configs are unchanged, and reviewer-disagreement reconciliation now follows the configured request-changes boundary.
- A roadmap section in the README outlining planned improvements.
- This `CHANGELOG.md`; each tagged release now sources its GitHub Release notes from the matching version section here.

## [0.1.3] - 2026-07-17

### Added

- Reviewer-disagreement reconciliation: when two reviewers land on opposite sides of the merge gate, a third read-only pass re-checks each blocking finding for substance and scope and decides the final verdict, so one reviewer's mistaken blocker no longer gates a correct pull request. The reconciliation and its verdict are shown in the posted review.

### Changed

- Hardened the review contract with a scope gate. A finding may only block or request changes when its `path:line` is a line the pull request adds or changes; pre-existing issues, code outside the diff, and behavior owned by third-party dependencies are surfaced as notes, never as merge blockers. Framework-behavior claims must be verified before they can block.

## [0.1.2] - 2026-07-16

### Changed

- Gated severity by scope: pre-existing defects found outside the pull request's changes are reported as notes and never block the merge.

## [0.1.1] - 2026-07-15

### Fixed

- A failed reviewer (for example a timeout) no longer posts a partial or broken review; the pull request is left unmarked and retried on the next poll.
- Stopped the review prompt from leaking into posted comments, history, or logs when a command fails or times out.

## [0.1.0] - 2026-07-15

### Added

- Initial release: a macOS menu-bar app that reviews GitHub pull requests requesting a review from the signed-in `gh` user, using local Claude and Codex CLIs in an isolated read-only worktree.
- Multiple repositories with independent enable/disable, a configurable polling interval, and pause/resume.
- Claude and Codex reviewers with per-reviewer model and effort settings, a global custom prompt, and mandatory `REVIEW.md` rules loaded from the trusted base commit.
- Strictest-verdict decision posted through `gh pr review`, with deduplication, activity history, logs, and saved review Markdown.
- DMG packaging and a tagged-release workflow that builds and publishes the app.

[Unreleased]: https://github.com/melihucar/review-bot/compare/v0.1.11...HEAD
[0.1.11]: https://github.com/melihucar/review-bot/compare/v0.1.9...v0.1.11
[0.1.9]: https://github.com/melihucar/review-bot/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/melihucar/review-bot/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/melihucar/review-bot/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/melihucar/review-bot/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/melihucar/review-bot/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/melihucar/review-bot/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/melihucar/review-bot/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/melihucar/review-bot/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/melihucar/review-bot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/melihucar/review-bot/releases/tag/v0.1.0
