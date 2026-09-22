import Foundation

enum ReviewEffort: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }
    var label: String {
        switch self {
        case .xhigh: "Extra high"
        case .max: "Max"
        default: rawValue.capitalized
        }
    }

    // Claude, Codex, and opencode expose different top-tier effort names, so
    // each reviewer only offers the levels its CLI accepts.
    static let claudeCases: [ReviewEffort] = [.low, .medium, .high, .max]
    static let codexCases: [ReviewEffort] = [.low, .medium, .high, .xhigh]
    static let opencodeCases: [ReviewEffort] = [.low, .medium, .high, .max]
}

/// How much of a pull request each review looks at.
enum ReviewScope: String, Codable, CaseIterable, Identifiable {
    /// Review the entire base…head diff every time (default, original behavior).
    case fullPullRequest = "full"
    /// Review only what changed since the commit we last posted a review on.
    case incremental = "incremental"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullPullRequest: "Whole PR"
        case .incremental: "New changes only"
        }
    }
}

/// What one reviewer consumed producing one review.
struct TokenUsage: Codable, Equatable {
    var inputTokens: Int
    /// Input tokens served from the provider's prompt cache; billed at a lower rate.
    var cachedInputTokens: Int
    var outputTokens: Int
    /// Number of provider calls. DeepSeek's agent loop makes many per review.
    var requests: Int
    /// `nil` whenever the cost is unknown — the provider reported none and no rates are
    /// configured, or rates are configured but a billed call's tokens went unreported, so
    /// multiplying them out would understate the spend. A missing cost must never be shown as
    /// `$0.00`: reading unknown as free is the failure cost reporting exists to prevent.
    var costUSD: Double?

    init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        requests: Int = 0,
        costUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.requests = requests
        self.costUSD = costUSD
    }

    var totalTokens: Int { inputTokens + cachedInputTokens + outputTokens }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            requests: lhs.requests + rhs.requests,
            costUSD: lhs.costUSD == nil && rhs.costUSD == nil
                ? nil
                : (lhs.costUSD ?? 0) + (rhs.costUSD ?? 0)
        )
    }

    /// Input tokens in total, cached and uncached. `inputTokens` alone is the uncached portion,
    /// which is the figure that matters for pricing but not the one a reader expects to see.
    var totalInputTokens: Int { inputTokens + cachedInputTokens }

    /// e.g. `24.1k in (11.0k cached) + 2.0k out over 7 calls`. The cached count is a subset of
    /// the input count, matching how providers report it.
    var tokenSummary: String {
        var input = "\(Self.abbreviated(totalInputTokens)) in"
        if cachedInputTokens > 0 {
            input += " (\(Self.abbreviated(cachedInputTokens)) cached)"
        }
        let joined = "\(input) + \(Self.abbreviated(outputTokens)) out"
        return requests > 1 ? "\(joined) over \(requests) calls" : joined
    }

    /// `nil` when cost is unknown, so callers can say so rather than imply it was free.
    var costSummary: String? {
        guard let costUSD else { return nil }
        return costUSD >= 1
            ? String(format: "$%.2f", costUSD)
            : String(format: "$%.4f", costUSD)
    }

    static func abbreviated(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return String(count)
    }
}

/// USD per million tokens, for providers that report tokens but not cost.
///
/// These are settings rather than constants on purpose: published prices change, and a stale
/// hardcoded rate would silently report the wrong number.
struct TokenPricing: Codable, Equatable {
    var inputPerMillion: Double
    var cachedInputPerMillion: Double
    var outputPerMillion: Double

    var isUnpriced: Bool {
        inputPerMillion <= 0 && cachedInputPerMillion <= 0 && outputPerMillion <= 0
    }

    func cost(for usage: TokenUsage) -> Double? {
        guard !isUnpriced else { return nil }
        return Double(usage.inputTokens) / 1_000_000 * inputPerMillion
            + Double(usage.cachedInputTokens) / 1_000_000 * cachedInputPerMillion
            + Double(usage.outputTokens) / 1_000_000 * outputPerMillion
    }

    /// DeepSeek's published `deepseek-chat` rates as of July 2026. Confirm against
    /// api-docs.deepseek.com — they are editable in Settings precisely because they drift.
    static let deepSeekDefault = TokenPricing(
        inputPerMillion: 0.27,
        cachedInputPerMillion: 0.07,
        outputPerMillion: 1.10
    )

    /// All rates zero: report tokens, no cost.
    static let unpriced = TokenPricing(
        inputPerMillion: 0,
        cachedInputPerMillion: 0,
        outputPerMillion: 0
    )

    /// Parses a rate typed or pasted into the settings field.
    ///
    /// Accepts both `0.27` and `0,27`. Providers publish rates with a dot, but a
    /// comma-decimal locale reads a pasted `0.27` as `27` — a hundredfold overstatement of
    /// spend — so the separator is normalised rather than left to the locale.
    static func parseRate(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty,
              let value = Double(normalized),
              value.isFinite,
              value >= 0 else {
            return nil
        }
        return value
    }

    /// Renders a rate for editing, always with a dot so it matches published pricing.
    static func renderRate(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// Where a reviewer gets its provider credentials.
enum ReviewerAuthMode: String, Codable, CaseIterable, Identifiable {
    /// Use whatever the reviewer's CLI is already signed in as. Review Bot passes no key.
    case session
    /// Use an API key held in the macOS Keychain.
    case apiKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: "Signed-in CLI"
        case .apiKey: "API key"
        }
    }
}

struct ReviewerConfiguration: Codable, Equatable {
    var enabled: Bool
    var model: String
    var effort: ReviewEffort
    /// Never holds the key itself — only which source to use. Keys live in the Keychain.
    var authMode: ReviewerAuthMode
    /// Only used by providers that report tokens but not cost. `nil` means "don't compute cost".
    var pricing: TokenPricing?
    /// How long this reviewer may spend on one review before it is cut off.
    ///
    /// Per reviewer rather than global because they do not cost the same: a signed-in CLI on a
    /// flat subscription can be given an hour on a large pull request, while a reviewer billed to
    /// your own key spends the whole time being charged. The default matches what every reviewer
    /// used before this was configurable.
    var timeoutMinutes: Int

    static let defaultTimeoutMinutes = 15
    /// Below a minute nothing finishes; the upper bound is a guard against a typo pinning a
    /// reviewer — and a metered bill — for a day.
    static let timeoutMinutesRange = 1...240

    /// The timeout as `ProcessRunner` and the DeepSeek budget want it.
    var timeoutSeconds: Int { timeoutMinutes * 60 }

    init(
        enabled: Bool,
        model: String,
        effort: ReviewEffort,
        authMode: ReviewerAuthMode = .session,
        pricing: TokenPricing? = nil,
        timeoutMinutes: Int = ReviewerConfiguration.defaultTimeoutMinutes
    ) {
        self.enabled = enabled
        self.model = model
        self.effort = effort
        self.authMode = authMode
        self.pricing = pricing
        self.timeoutMinutes = Self.clampedTimeout(timeoutMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case model
        case effort
        case authMode
        case pricing
        case timeoutMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try values.decodeIfPresent(ReviewEffort.self, forKey: .effort) ?? .high
        authMode = try values.decodeIfPresent(ReviewerAuthMode.self, forKey: .authMode) ?? .session
        pricing = try values.decodeIfPresent(TokenPricing.self, forKey: .pricing)
        // Clamped rather than trusted: this one bounds a running process, and a config written by
        // hand with `0` would otherwise cut every review off before it started.
        timeoutMinutes = Self.clampedTimeout(
            try values.decodeIfPresent(Int.self, forKey: .timeoutMinutes)
                ?? Self.defaultTimeoutMinutes
        )
    }

    private static func clampedTimeout(_ minutes: Int) -> Int {
        min(max(minutes, timeoutMinutesRange.lowerBound), timeoutMinutesRange.upperBound)
    }
}

struct RepositoryConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var githubSlug: String
    var enabled = true
}

/// How many times one review request may fail — a reviewer that errors or returns
/// no verdict, or a post GitHub rejects — before Review Bot stops retrying it.
/// Stored as a plain number so `config.json` stays readable, with `0` meaning
/// "keep retrying"; absent means the config predates the setting and adopts the
/// bounded default.
enum FailureBudget: Codable, Equatable {
    case unlimited
    case attempts(Int)

    static let `default` = FailureBudget.attempts(5)

    /// The attempt ceiling, or `nil` when retries are unlimited.
    var limit: Int? {
        switch self {
        case .unlimited: return nil
        case let .attempts(count): return count
        }
    }

    init(limit: Int?) {
        if let limit {
            self = .attempts(max(1, limit))
        } else {
            self = .unlimited
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        self = value > 0 ? .attempts(value) : .unlimited
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(limit ?? 0)
    }
}

struct ReviewBotConfiguration: Codable, Equatable {
    var repositories: [RepositoryConfiguration]
    var pollIntervalMinutes: Int
    var isPaused: Bool
    var claude: ReviewerConfiguration
    var codex: ReviewerConfiguration
    var opencode: ReviewerConfiguration
    var deepseek: ReviewerConfiguration
    /// Reviewers the developer added themselves, each an OpenAI-compatible `chat/completions`
    /// endpoint. This is the list that makes the panel arbitrarily wide: the four above are
    /// backends Review Bot ships support for, these are however many models the developer wants
    /// reading the pull request.
    var customReviewers: [CustomReviewerConfiguration]
    var customPrompt: String
    /// Whether the posted review reports what the API-key reviewers consumed.
    var includeUsageInReview: Bool
    var decisionPolicy: DecisionPolicy
    var reviewScope: ReviewScope
    /// Maximum number of times a single pull request will be reviewed (across new
    /// commits and re-requests). Counts reviews that actually posted; `nil` means
    /// unlimited.
    var maxReviewRoundsPerPR: Int?
    /// When to stop retrying a review request that keeps failing. Attempts are also
    /// spaced out by a widening backoff, so a permanently broken reviewer costs a
    /// bounded amount of work instead of re-running on every poll forever.
    var failureBudget: FailureBudget
    /// How many pull requests a single poll reviews at the same time. Every one of
    /// them runs every enabled reviewer, so this bounds the fan-out of CLI processes
    /// (and the API traffic behind them); `1` restores the old one-at-a-time poll.
    var maxConcurrentReviews: Int
    /// The GitHub account to review as — one `gh` is signed in to — or empty for whatever
    /// account `gh` currently has active. Review requests are searched for, the fetch is
    /// made, and the review is posted as this account; see `GitHubAccountEnvironment`.
    var githubAccount: String

    /// DeepSeek has no CLI to inherit a session from, so it is API-key-only and starts disabled.
    static let defaultDeepSeek = ReviewerConfiguration(
        enabled: false,
        model: "deepseek-chat",
        effort: .high,
        authMode: .apiKey,
        pricing: ReviewerName.deepseek.defaultPricing
    )

    static let `default` = ReviewBotConfiguration(
        repositories: [],
        pollIntervalMinutes: 15,
        isPaused: false,
        claude: ReviewerConfiguration(
            enabled: true,
            model: "claude-opus-5",
            effort: .high
        ),
        codex: ReviewerConfiguration(
            enabled: true,
            model: "gpt-5.6-sol",
            effort: .high
        ),
        // opencode is opt-in: the deepseek-v4-flash-free model is free, so the
        // default pairs it with max reasoning effort at no cost. It signs in through its
        // own config directory, so it never takes a key.
        opencode: ReviewerConfiguration(
            enabled: false,
            model: "opencode/deepseek-v4-flash-free",
            effort: .max,
            authMode: .session
        ),
        deepseek: defaultDeepSeek,
        customReviewers: [],
        customPrompt: "",
        includeUsageInReview: true,
        decisionPolicy: .default,
        reviewScope: .fullPullRequest,
        maxReviewRoundsPerPR: nil,
        failureBudget: .default,
        maxConcurrentReviews: 3,
        githubAccount: ""
    )

    /// `decoded` unless it is blank, in which case the shipped default.
    private static func model(_ decoded: String, or fallback: String) -> String {
        decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : decoded
    }

    private enum CodingKeys: String, CodingKey {
        case repositories
        case pollIntervalMinutes
        case isPaused
        case claude
        case codex
        case opencode
        case deepseek
        case customReviewers
        case customPrompt
        case includeUsageInReview
        case decisionPolicy
        case reviewScope
        case maxReviewRoundsPerPR
        case failureBudget
        case maxConcurrentReviews
        case githubAccount
    }

    init(
        repositories: [RepositoryConfiguration],
        pollIntervalMinutes: Int,
        isPaused: Bool,
        claude: ReviewerConfiguration,
        codex: ReviewerConfiguration,
        opencode: ReviewerConfiguration,
        deepseek: ReviewerConfiguration = ReviewBotConfiguration.defaultDeepSeek,
        customReviewers: [CustomReviewerConfiguration] = [],
        customPrompt: String,
        includeUsageInReview: Bool = true,
        decisionPolicy: DecisionPolicy = .default,
        reviewScope: ReviewScope = .fullPullRequest,
        maxReviewRoundsPerPR: Int? = nil,
        failureBudget: FailureBudget = .default,
        maxConcurrentReviews: Int = 3,
        githubAccount: String = ""
    ) {
        self.repositories = repositories
        self.pollIntervalMinutes = pollIntervalMinutes
        self.isPaused = isPaused
        self.claude = claude
        self.codex = codex
        self.opencode = opencode
        self.deepseek = deepseek
        self.customReviewers = customReviewers
        self.customPrompt = customPrompt
        self.includeUsageInReview = includeUsageInReview
        self.decisionPolicy = decisionPolicy
        self.reviewScope = reviewScope
        self.maxReviewRoundsPerPR = maxReviewRoundsPerPR.map { max(1, $0) }
        self.failureBudget = failureBudget
        self.maxConcurrentReviews = max(1, maxConcurrentReviews)
        self.githubAccount = githubAccount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try values.decodeIfPresent(
            [RepositoryConfiguration].self,
            forKey: .repositories
        ) ?? []
        pollIntervalMinutes = try values.decodeIfPresent(
            Int.self,
            forKey: .pollIntervalMinutes
        ) ?? 15
        isPaused = try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        claude = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .claude
        ) ?? ReviewBotConfiguration.default.claude
        codex = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .codex
        ) ?? ReviewBotConfiguration.default.codex
        opencode = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .opencode
        ) ?? ReviewBotConfiguration.default.opencode
        deepseek = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .deepseek
        ) ?? ReviewBotConfiguration.defaultDeepSeek
        if !ReviewEffort.claudeCases.contains(claude.effort) {
            claude.effort = .high
        }
        if !ReviewEffort.codexCases.contains(codex.effort) {
            codex.effort = .high
        }
        if !ReviewEffort.opencodeCases.contains(opencode.effort) {
            opencode.effort = .max
        }
        // `ReviewerConfiguration.init(from:)` decodes a missing `model` to an empty string so a
        // hand-edited config still loads instead of throwing the whole file away. An empty model
        // is not runnable, though — the CLI would be invoked as `--model ""` and fail in a way
        // that reads as a provider outage — so fall back to the shipped default here, where the
        // reviewer's identity is known, exactly as an out-of-range effort does above.
        claude.model = Self.model(claude.model, or: Self.default.claude.model)
        codex.model = Self.model(codex.model, or: Self.default.codex.model)
        opencode.model = Self.model(opencode.model, or: Self.default.opencode.model)
        // opencode signs in through its own config directory and takes no key, so there is
        // nothing to hand it in API-key mode. Pinning the mode here keeps a hand-edited or
        // migrated config from selecting one where Review Bot would inject nothing and still
        // count the reviewer as metered.
        opencode.authMode = .session
        // DeepSeek is reached over HTTP, so there is no CLI session to fall back on.
        deepseek.authMode = .apiKey
        // A config saved before per-token pricing existed has no rates, and leaving that as
        // `nil` would leave an upgraded install permanently unable to report DeepSeek's cost.
        // Backfilling here rather than writing the file back on load means an unrecognised key
        // someone added by hand survives until the next real settings change, as it always has.
        if deepseek.pricing == nil {
            deepseek.pricing = ReviewerName.deepseek.defaultPricing
        }
        // Absent from every configuration written before custom reviewers existed, and a list
        // whose elements each decode defensively — so one unreadable row cannot cost the
        // developer the rest of their settings.
        customReviewers = try values.decodeIfPresent(
            [CustomReviewerConfiguration].self,
            forKey: .customReviewers
        ) ?? []
        customPrompt = try values.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        includeUsageInReview = try values.decodeIfPresent(
            Bool.self,
            forKey: .includeUsageInReview
        ) ?? true
        decisionPolicy = try values.decodeIfPresent(
            DecisionPolicy.self,
            forKey: .decisionPolicy
        ) ?? .default
        reviewScope = try values.decodeIfPresent(
            ReviewScope.self,
            forKey: .reviewScope
        ) ?? .fullPullRequest
        if let rounds = try values.decodeIfPresent(Int.self, forKey: .maxReviewRoundsPerPR) {
            maxReviewRoundsPerPR = max(1, rounds)
        } else {
            maxReviewRoundsPerPR = nil
        }
        // Absent from a pre-existing config: adopt the bounded default rather than
        // the historical unbounded retry.
        failureBudget = try values.decodeIfPresent(
            FailureBudget.self,
            forKey: .failureBudget
        ) ?? .default
        maxConcurrentReviews = max(
            1,
            try values.decodeIfPresent(Int.self, forKey: .maxConcurrentReviews) ?? 3
        )
        githubAccount = (try values.decodeIfPresent(String.self, forKey: .githubAccount) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HistoryEventKind: String, Codable {
    case requestDetected
    case reviewStarted
    case approved
    case changesRequested
    case commented
    case failed
    /// A pull request Review Bot had reviewed was merged. Recorded once per pull request,
    /// from the poll that first sees it merged, so the statistics can say whether a
    /// change request was followed through rather than only re-reviewed.
    case merged

    var label: String {
        switch self {
        case .requestDetected: "Review requested"
        case .reviewStarted: "Review started"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .commented: "Comment posted"
        case .failed: "Failed"
        case .merged: "Merged"
        }
    }

    var symbol: String {
        switch self {
        case .requestDetected: "bell.badge"
        case .reviewStarted: "sparkles"
        case .approved: "checkmark.circle.fill"
        case .changesRequested: "exclamationmark.octagon.fill"
        case .commented: "text.bubble.fill"
        case .failed: "xmark.circle.fill"
        case .merged: "arrow.triangle.merge"
        }
    }

    /// The kinds that end a review: a posted decision or a failure.
    var endsAReview: Bool {
        switch self {
        case .approved, .changesRequested, .commented, .failed: true
        case .requestDetected, .reviewStarted, .merged: false
        }
    }

    /// The kinds that mean a review was posted to GitHub.
    var isPostedDecision: Bool {
        switch self {
        case .approved, .changesRequested, .commented: true
        case .requestDetected, .reviewStarted, .failed, .merged: false
        }
    }
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var kind: HistoryEventKind
    var repositoryName: String
    var repositorySlug: String
    var pullRequestNumber: Int?
    var pullRequestTitle: String?
    var pullRequestURL: String?
    var message: String
    /// Combined usage for the review this entry describes, so spend can be totalled from
    /// `history.json` later. Absent on entries written before usage was tracked.
    var usage: TokenUsage?
    /// When GitHub recorded the review request this review answers — the timestamp of the
    /// `review_requested` event, when the timeline had one. `date - requestedAt` is how long
    /// the author waited for Review Bot. Absent on entries written before it was tracked and
    /// on requests whose marker fell back to the head commit.
    var requestedAt: Date?
    /// When the review of this pull request began — set on the entries that end a review, so
    /// `date - startedAt` is how long the review took from checkout to the posted decision.
    var startedAt: Date?
    /// The head commit the review looked at, so a later approval at a *different* commit
    /// can be told from a re-review of the same one.
    var headCommit: String?

    /// How long the review took, for the entries that end one.
    var reviewDuration: TimeInterval? {
        guard kind.endsAReview, let startedAt else { return nil }
        return max(0, date.timeIntervalSince(startedAt))
    }

    /// How long the author waited between requesting the review and the posted decision.
    var responseTime: TimeInterval? {
        guard kind.isPostedDecision, let requestedAt else { return nil }
        return max(0, date.timeIntervalSince(requestedAt))
    }

    /// `slug#number`, the key the statistics group a pull request's entries by.
    var pullRequestKey: String? {
        pullRequestNumber.map { "\(repositorySlug)#\($0)" }
    }
}

struct ReviewQueueItem: Codable, Equatable, Identifiable {
    let repositoryName: String
    let repositorySlug: String
    let pullRequestNumber: Int
    let pullRequestTitle: String
    let pullRequestURL: String?

    var id: String { "\(repositorySlug)#\(pullRequestNumber)" }

    init?(entry: HistoryEntry) {
        guard let number = entry.pullRequestNumber,
              let title = entry.pullRequestTitle else {
            return nil
        }
        repositoryName = entry.repositoryName
        repositorySlug = entry.repositorySlug
        pullRequestNumber = number
        pullRequestTitle = title
        pullRequestURL = entry.pullRequestURL
    }
}

/// Declaration order is load-bearing beyond this enum: `enabledReviewers` maps `allCases`,
/// which fixes the order reviewers appear in the posted panel and the order
/// `ReviewEngine.runReconciliation` prefers an adjudicator in (Claude, then Codex, then
/// opencode). DeepSeek comes last deliberately, so the one reviewer that always bills a key
/// never becomes the adjudicator while a session-backed CLI is available.
enum ReviewerName: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case opencode = "opencode"
    case deepseek = "DeepSeek"

    var id: String { rawValue }

    /// The CLI this reviewer shells out to, or `nil` when it is reached over HTTP.
    var commandName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .deepseek: nil
        }
    }

    /// Only CLI-backed reviewers can borrow an existing login session.
    var supportsSessionAuth: Bool { commandName != nil }

    /// Whether a key of the developer's own can be pointed at this reviewer at all: either it
    /// is a CLI that reads one from its environment, or it has no CLI and a key is the only way
    /// to reach it. opencode is neither — it authenticates through its own config directory —
    /// so offering it an API-key mode would produce a reviewer Review Bot cannot credential.
    var supportsAPIKeyAuth: Bool { apiKeyEnvironmentVariable != nil || commandName == nil }

    /// The variable a CLI-backed reviewer reads its API key from, when the developer
    /// chooses key auth over the CLI's own session.
    var apiKeyEnvironmentVariable: String? {
        switch self {
        case .claude: "ANTHROPIC_API_KEY"
        case .codex: "OPENAI_API_KEY"
        // opencode is credentialed through OPENCODE_CONFIG_DIR, not through an injected key,
        // so there is nothing to hand its child process.
        case .opencode: nil
        case .deepseek: nil
        }
    }

    /// The variable Review Bot itself reads a key from, taking precedence over the Keychain.
    /// Unlike `apiKeyEnvironmentVariable` — which is outbound, handed to a CLI child process —
    /// this is inbound, and every reviewer has one including DeepSeek, which has no CLI. It is
    /// how `make run`, a test, or a one-off probe supplies a key without touching the
    /// developer's Keychain. Note that a GUI app started from Finder or at login inherits
    /// launchd's environment, not a shell's, so this is a development affordance: the packaged
    /// app still reads the Keychain. opencode's entry exists only because the property is
    /// total; it is never consulted, since opencode is pinned to session auth.
    var apiKeyOverrideEnvironmentVariable: String {
        switch self {
        case .claude: "ANTHROPIC_API_KEY"
        case .codex: "OPENAI_API_KEY"
        case .opencode: "OPENCODE_API_KEY"
        case .deepseek: "DEEPSEEK_API_KEY"
        }
    }

    /// DeepSeek is called through the chat-completions API, which has no effort control.
    var usesEffortSetting: Bool { self != .deepseek }

    /// Whether the reviewer tells us what it spent. Claude's CLI reports both tokens and a
    /// dollar figure under `--output-format json`; DeepSeek's API reports tokens only, so its
    /// cost is derived from configured prices; Codex and opencode print the review and nothing
    /// else, so there is no usage envelope to read.
    var reportsTokenUsage: Bool {
        switch self {
        case .claude: true
        case .codex: false
        case .opencode: false
        case .deepseek: true
        }
    }

    /// The rates a reviewer starts with, and `nil` for one that needs none — a CLI that reports
    /// its own dollar figure, or one that reports no usage at all.
    ///
    /// It lives on the case rather than in the settings view so that a second provider priced
    /// this way cannot be given DeepSeek's rates by a Reset button that was only ever written
    /// for DeepSeek.
    var defaultPricing: TokenPricing? {
        switch self {
        case .claude: nil
        case .codex: nil
        case .opencode: nil
        case .deepseek: .deepSeekDefault
        }
    }

    /// True when cost can only be computed from `ReviewerConfiguration.pricing`.
    var needsConfiguredPricing: Bool { defaultPricing != nil }

    var efforts: [ReviewEffort] {
        switch self {
        case .claude: ReviewEffort.claudeCases
        case .codex: ReviewEffort.codexCases
        case .opencode: ReviewEffort.opencodeCases
        case .deepseek: []
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "brain.head.profile"
        case .codex: "terminal.fill"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .deepseek: "cloud.fill"
        }
    }
}

/// A reviewer the developer added themselves, reached over an OpenAI-compatible
/// `chat/completions` endpoint.
///
/// This is what lets one pull request be read by many models. `ReviewerName` is a closed set of
/// *backends* Review Bot knows how to drive; a custom reviewer is a *panel member* instead — a
/// base URL, a model name and a key — so a second, third or tenth model joins the panel without
/// a new enum case, a new switch arm, or a CLI to install. Every one of them runs the same
/// in-process agent loop the built-in DeepSeek reviewer runs, behind the same read-only
/// `WorktreeTools` sandbox, so the read-only guarantee is not restated per provider.
struct CustomReviewerConfiguration: Codable, Equatable, Identifiable {
    /// Stable for the life of the reviewer, and the only thing its stored key is filed under —
    /// so renaming a reviewer, or pointing it at a different model, never orphans its credential.
    var id: UUID
    /// What the posted panel calls this reviewer.
    var name: String
    /// The API root, *without* the `chat/completions` suffix the client appends —
    /// `https://openrouter.ai/api/v1`, `https://api.z.ai/api/paas/v4`, and so on.
    var baseURL: String
    var model: String
    var enabled: Bool
    /// Rates in USD per million tokens. Unlike the built-in reviewers there is no default that
    /// could be right, so a new custom reviewer starts unpriced: `TokenPricing.cost(for:)`
    /// returns `nil` for all-zero rates, and the review reports tokens without implying the
    /// call was free.
    var pricing: TokenPricing?
    /// How long this reviewer may spend on one review, in minutes — every custom reviewer bills
    /// a key, so this is also its spend ceiling.
    var timeoutMinutes: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        model: String = "",
        enabled: Bool = true,
        pricing: TokenPricing? = TokenPricing.unpriced,
        timeoutMinutes: Int = ReviewerConfiguration.defaultTimeoutMinutes
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.enabled = enabled
        self.pricing = pricing
        self.timeoutMinutes = timeoutMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, enabled, pricing, timeoutMinutes
    }

    /// Defensive like every other decoder here, with one addition: a row whose id is missing
    /// gets a fresh one rather than throwing the whole configuration away. That loses the row's
    /// stored key, which is recoverable; refusing to load `config.json` is not.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        pricing = try values.decodeIfPresent(TokenPricing.self, forKey: .pricing)
            ?? TokenPricing.unpriced
        timeoutMinutes = try values.decodeIfPresent(Int.self, forKey: .timeoutMinutes)
            ?? ReviewerConfiguration.defaultTimeoutMinutes
    }

    var identity: ReviewerIdentity { .custom(id) }

    /// Never blank: an unnamed reviewer still has to be distinguishable in the posted panel and
    /// in the activity log, so it falls back to its model and then to a fixed label.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Custom reviewer" : model
    }

    /// The endpoint root, or `nil` when what was typed is not a usable http(s) URL.
    ///
    /// Checked here rather than at the call site so a half-filled row cannot reach the network:
    /// `isRunnable` is what `enabledReviewers` filters on, and a row that fails this never runs
    /// at all instead of failing once per poll with a URL error.
    var endpointURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /// Whether this row is complete enough to run. An incomplete row is not an error — it is a
    /// card someone is still filling in.
    var isRunnable: Bool {
        endpointURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The uniform settings view the engine works in. Effort is fixed because a
    /// chat-completions endpoint has no effort control, and the auth mode is fixed because a key
    /// is the only way in — the same two constraints the built-in DeepSeek reviewer has.
    var reviewerConfiguration: ReviewerConfiguration {
        ReviewerConfiguration(
            enabled: enabled,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            effort: .high,
            authMode: .apiKey,
            pricing: pricing,
            timeoutMinutes: timeoutMinutes
        )
    }
}

/// Which panel member a result, a credential, or a settings row belongs to.
///
/// `ReviewerName` names a backend; this names a *seat on the panel*, and the two stopped being
/// the same thing once several custom reviewers could share the one chat-completions backend
/// with different endpoints, models and keys. Everything downstream — credentials, metering,
/// the posted panel — keys off this, so putting a second model in front of a pull request does
/// not mean adding a case to `ReviewerName`.
enum ReviewerIdentity: Hashable, Sendable, Codable {
    case builtIn(ReviewerName)
    case custom(UUID)

    /// The account name the platform credential store files this reviewer's key under.
    ///
    /// A built-in keeps its historical account — its `ReviewerName` raw value — so an existing
    /// Keychain or Credential Manager item survives this change untouched.
    var credentialAccount: String {
        switch self {
        case let .builtIn(name): name.rawValue
        case let .custom(id): "custom:\(id.uuidString)"
        }
    }

    /// The variable Review Bot reads a key from before consulting the platform store. A custom
    /// reviewer's is derived from its id rather than its name, so renaming the reviewer in
    /// Settings does not silently stop an exported key from being picked up.
    var apiKeyOverrideEnvironmentVariable: String {
        switch self {
        case let .builtIn(name): name.apiKeyOverrideEnvironmentVariable
        case let .custom(id):
            "REVIEW_BOT_KEY_" + id.uuidString.replacingOccurrences(of: "-", with: "_")
        }
    }

    /// False only for a reviewer Review Bot has nowhere to put a key for — opencode, which
    /// authenticates through its own configuration directory. Every custom reviewer is reached
    /// over HTTP, so a key is the only way in.
    var acceptsAPIKey: Bool {
        switch self {
        case let .builtIn(name): name.supportsAPIKeyAuth
        case .custom: true
        }
    }

    /// A flat string form for JSON and URL paths, where an enum with an associated value would
    /// force the dashboard's JavaScript to understand Swift's `Codable` shape. A built-in keeps
    /// its own name; a custom reviewer is its id, and the two can never collide because no
    /// reviewer is named like a UUID.
    var wireIdentifier: String {
        switch self {
        case let .builtIn(name): name.rawValue
        case let .custom(id): id.uuidString
        }
    }

    init?(wireIdentifier: String) {
        if let name = ReviewerName(rawValue: wireIdentifier) {
            self = .builtIn(name)
        } else if let id = UUID(uuidString: wireIdentifier) {
            self = .custom(id)
        } else {
            return nil
        }
    }

    /// The built-in backend, or `nil` for a custom chat-completions reviewer. Callers that can
    /// only act on the fixed reviewers — the CLI availability badges, the adjudicator
    /// preference — filter on this rather than assuming every seat is a `ReviewerName`.
    var builtInName: ReviewerName? {
        switch self {
        case let .builtIn(name): name
        case .custom: nil
        }
    }
}

/// What a panel seat is backed by. The `builtIn` payload is what keeps
/// `ReviewEngine.runReviewerOnce`'s dispatch exhaustive over `ReviewerName`, which is still the
/// only compile-time guarantee that a newly added backend is actually invoked.
enum ReviewerKind: Equatable {
    case builtIn(ReviewerName)
    case custom(CustomReviewerConfiguration)
}

/// A panel seat paired with its settings, so the engine can treat every reviewer uniformly.
struct ConfiguredReviewer: Equatable {
    let kind: ReviewerKind
    let configuration: ReviewerConfiguration
    /// What the posted panel, the reconciliation prompt and the usage table call this seat.
    /// Usually the reviewer's own name, but `disambiguated(_:)` may qualify it — nothing stops
    /// two custom rows being given the same name, and two identically labelled panels in one
    /// review are indistinguishable to a reader and to the adjudicator.
    let displayName: String

    init(kind: ReviewerKind, configuration: ReviewerConfiguration, displayName: String? = nil) {
        self.kind = kind
        self.configuration = configuration
        self.displayName = displayName ?? Self.defaultDisplayName(for: kind)
    }

    init(name: ReviewerName, configuration: ReviewerConfiguration) {
        self.init(kind: .builtIn(name), configuration: configuration)
    }

    init(custom: CustomReviewerConfiguration) {
        self.init(kind: .custom(custom), configuration: custom.reviewerConfiguration)
    }

    private static func defaultDisplayName(for kind: ReviewerKind) -> String {
        switch kind {
        case let .builtIn(name): name.rawValue
        case let .custom(custom): custom.displayName
        }
    }

    var identity: ReviewerIdentity {
        switch kind {
        case let .builtIn(name): .builtIn(name)
        case let .custom(custom): custom.identity
        }
    }

    /// The built-in backend, or `nil` for a custom reviewer.
    var name: ReviewerName? { identity.builtInName }

    /// Makes every seat's name unique, in order, without renaming anything the developer can
    /// see in Settings.
    ///
    /// A repeated name is qualified by its model first, because that is the distinction the
    /// reader actually cares about; if that still collides — the same model added twice — a
    /// counter is appended. Built-in reviewers can never collide with each other, so in practice
    /// this only touches custom rows.
    static func disambiguated(_ reviewers: [ConfiguredReviewer]) -> [ConfiguredReviewer] {
        let counts = reviewers.reduce(into: [String: Int]()) { counts, reviewer in
            counts[reviewer.displayName, default: 0] += 1
        }
        var used: Set<String> = []
        return reviewers.map { reviewer in
            guard counts[reviewer.displayName, default: 0] > 1 else {
                used.insert(reviewer.displayName)
                return reviewer
            }
            let model = reviewer.configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
            var candidate = model.isEmpty
                ? reviewer.displayName
                : "\(reviewer.displayName) (\(model))"
            var suffix = 2
            while used.contains(candidate) {
                candidate = model.isEmpty
                    ? "\(reviewer.displayName) \(suffix)"
                    : "\(reviewer.displayName) (\(model)) \(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            return ConfiguredReviewer(
                kind: reviewer.kind,
                configuration: reviewer.configuration,
                displayName: candidate
            )
        }
    }
}

extension ReviewBotConfiguration {
    func settings(for reviewer: ReviewerName) -> ReviewerConfiguration {
        switch reviewer {
        case .claude: claude
        case .codex: codex
        case .opencode: opencode
        case .deepseek: deepseek
        }
    }

    /// The settings behind any panel seat, built-in or custom. A custom id that is no longer in
    /// the list — a reviewer deleted while a review it was part of was still running — resolves
    /// to a disabled, unmetered configuration rather than trapping.
    func settings(for identity: ReviewerIdentity) -> ReviewerConfiguration {
        switch identity {
        case let .builtIn(name):
            return settings(for: name)
        case let .custom(id):
            guard let custom = customReviewers.first(where: { $0.id == id }) else {
                return ReviewerConfiguration(
                    enabled: false,
                    model: "",
                    effort: .high,
                    authMode: .session
                )
            }
            return custom.reviewerConfiguration
        }
    }

    /// Enabled reviewers in a stable order, so posted reviews and history read the same way on
    /// every run: the built-in backends in `ReviewerName` declaration order, then the custom
    /// reviewers in the order they were added.
    ///
    /// A custom row that is still half-filled is skipped rather than run. It has no endpoint to
    /// reach, so running it would put one failed reviewer in every posted panel until someone
    /// finished typing.
    var enabledReviewers: [ConfiguredReviewer] {
        let builtIn = ReviewerName.allCases
            .map { ConfiguredReviewer(name: $0, configuration: settings(for: $0)) }
            .filter(\.configuration.enabled)
        let custom = customReviewers
            .filter { $0.enabled && $0.isRunnable }
            .map(ConfiguredReviewer.init(custom:))
        return ConfiguredReviewer.disambiguated(builtIn + custom)
    }
}

enum ReviewVerdict: String, Codable, CaseIterable {
    case blocking = "BLOCKING"
    case shouldFix = "SHOULD_FIX"
    case nitsOnly = "NITS_ONLY"
    case clean = "CLEAN"

    var rank: Int {
        switch self {
        case .blocking: 3
        case .shouldFix: 2
        case .nitsOnly: 1
        case .clean: 0
        }
    }
}

/// Why a reviewer failed, to the extent its own output says so. The only distinction that
/// matters here is whether calling it again could plausibly produce a different answer.
enum ReviewerFailureClass: Equatable {
    /// The same call will fail the same way: an exhausted quota, a rejected credential, a
    /// model the account may not use. Retrying only spends wall time.
    case terminal
    /// Might succeed on a second try — a crash, a dropped connection, a 5xx, a missing
    /// verdict line.
    case transient

    /// Deliberately conservative: anything unrecognised is `transient`. Mistaking a
    /// recoverable failure for a terminal one silently drops a reviewer from the panel,
    /// while the reverse costs a single extra CLI call — a cost the retry already accepts.
    /// The markers are phrases a CLI emits about *itself*, long enough not to fire on a
    /// pull request that happens to discuss quotas or authentication.
    static func classify(_ message: String) -> ReviewerFailureClass {
        let haystack = message.lowercased()
        let terminalMarkers = [
            "usage limit",
            "rate limit exceeded",
            "insufficient_quota",
            "exceeded your current quota",
            "is not supported when using",
            "invalid api key",
            "invalid_api_key",
            "authentication_error",
            "authentication failed",
            "not authenticated",
            "please run `codex login`",
            "please run `claude login`",
            "credit balance is too low",
            // DeepSeek answers a bad key with "Authentication Fails" and an empty account
            // with "Insufficient Balance"; both arrive wrapped in `<provider> returned HTTP …`.
            "authentication fails",
            "insufficient balance",
            // Deliberately not anchored to a provider name. Every chat-completions reviewer —
            // DeepSeek and every custom endpoint — phrases its HTTP failures the same way, and
            // 401 (rejected key) and 402 (no balance) fail identically however often they are
            // called. Anchoring these to "deepseek" would silently spend the retry budget, and
            // then the review's failure budget, on every custom reviewer with a bad key.
            "returned http 401",
            "returned http 402",
            // Review Bot's own message for a reviewer set to API-key auth whose key is absent
            // or whose Keychain prompt was denied. Only Settings can fix that, so retrying
            // would spend the failure budget on a request that cannot start.
            "key could not be read",
            // Likewise a custom reviewer whose endpoint does not parse: there is nowhere to send
            // the request, and a second attempt sends it to the same nowhere.
            "no usable api base url",
            // A reviewer that reported it could not assess the pull request. Not a provider
            // failure at all — the call succeeded — but a second call re-reads the same
            // unreadable evidence and reaches the same conclusion, and for a metered reviewer
            // that is another full bill for the same non-answer.
            "could not assess this pull request",
        ]
        return terminalMarkers.contains { haystack.contains($0) } ? .terminal : .transient
    }
}

struct ReviewerResult: Equatable {
    /// Which panel seat produced this, built-in or custom.
    var reviewer: ReviewerIdentity
    /// What to call that seat in the posted panel and the log. Carried on the result rather than
    /// looked up from the configuration, so a review already in flight still names a custom
    /// reviewer correctly after it is renamed or removed in Settings.
    var displayName: String
    var model: String
    var output: String
    var verdict: ReviewVerdict?
    var failure: String?
    /// True when the reviewer ran out its own timeout. Re-running it inside the same
    /// review would spend that timeout again on a CLI that is most likely still hung,
    /// so these are left to the next poll instead of retried in place.
    var timedOut = false
    /// `nil` when the reviewer cannot report what it consumed. When a reviewer is retried
    /// inside one review this holds every attempt's spend, not the last one's — a discarded
    /// first attempt still billed the key.
    var usage: TokenUsage?

    /// `nil` when the reviewer finished; otherwise whether a second call could help.
    var failureClass: ReviewerFailureClass? {
        guard let failure else { return nil }
        return ReviewerFailureClass.classify(failure)
    }

    /// Whether this reviewer withdrew its own verdict by reporting it could not assess the pull
    /// request. Distinct from a failure: the call succeeded and the reviewer answered honestly,
    /// which is why a panel of nothing but these is still worth posting — the author is told why
    /// no review happened instead of being left with silence.
    var couldNotAssess: Bool {
        verdict == nil && (failure?.contains("could not assess this pull request") ?? false)
    }

    /// Whether running this reviewer again right now is worth the wall time: a crash,
    /// a transient API error, or a missing verdict line may well succeed on a second
    /// try; a timeout or an exhausted quota will not.
    var isWorthRetrying: Bool {
        guard !timedOut, failureClass != .terminal else { return false }
        return failure != nil || verdict == nil
    }

    /// Convenience for the built-in reviewers, whose display name is their `ReviewerName`.
    init(
        reviewer: ReviewerName,
        model: String,
        output: String,
        verdict: ReviewVerdict?,
        failure: String?,
        timedOut: Bool = false,
        usage: TokenUsage? = nil
    ) {
        self.init(
            reviewer: .builtIn(reviewer),
            displayName: reviewer.rawValue,
            model: model,
            output: output,
            verdict: verdict,
            failure: failure,
            timedOut: timedOut,
            usage: usage
        )
    }

    init(
        reviewer: ReviewerIdentity,
        displayName: String,
        model: String,
        output: String,
        verdict: ReviewVerdict?,
        failure: String?,
        timedOut: Bool = false,
        usage: TokenUsage? = nil
    ) {
        self.reviewer = reviewer
        self.displayName = displayName
        self.model = model
        self.output = output
        self.verdict = verdict
        self.failure = failure
        self.timedOut = timedOut
        self.usage = usage
    }
}

enum ReviewDecision: String, Codable, CaseIterable, Identifiable {
    case approve = "approve"
    case requestChanges = "request_changes"
    case comment = "comment"

    var id: String { rawValue }

    /// Severity ordering used to combine per-verdict actions across reviewers:
    /// requestChanges (strictest) > comment > approve.
    var rank: Int {
        switch self {
        case .requestChanges: 2
        case .comment: 1
        case .approve: 0
        }
    }

    var title: String {
        switch self {
        case .approve: "Approved"
        case .requestChanges: "Changes requested"
        case .comment: "Commented"
        }
    }

    /// User-facing label for the decision-policy pickers.
    var actionLabel: String {
        switch self {
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        case .comment: "Leave it to me"
        }
    }

    var ghArgument: String {
        switch self {
        case .approve: "--approve"
        case .requestChanges: "--request-changes"
        case .comment: "--comment"
        }
    }

    var historyKind: HistoryEventKind {
        switch self {
        case .approve: .approved
        case .requestChanges: .changesRequested
        case .comment: .commented
        }
    }
}

/// Maps each configurable reviewer verdict to the GitHub action the bot takes.
/// `BLOCKING` is always `.requestChanges` and is not user-configurable.
struct DecisionPolicy: Codable, Equatable {
    var shouldFix: ReviewDecision
    var nitsOnly: ReviewDecision
    var clean: ReviewDecision

    static let `default` = DecisionPolicy(
        shouldFix: .requestChanges,
        nitsOnly: .approve,
        clean: .approve
    )

    func action(for verdict: ReviewVerdict) -> ReviewDecision {
        switch verdict {
        case .blocking: .requestChanges
        case .shouldFix: shouldFix
        case .nitsOnly: nitsOnly
        case .clean: clean
        }
    }
}

struct PullRequestSummary: Decodable {
    let number: Int
    let title: String
    let url: String
}

struct PullRequestMetadata: Decodable {
    let title: String
    let headRefOid: String
    let baseRefName: String
    let baseRefOid: String
    let url: String
}

struct InspectedRepository {
    let name: String
    let path: String
    let githubSlug: String
}
