import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model, settings: model.settings)
                .tabItem { Label("Repositories", systemImage: "folder.badge.gearshape") }

            ReviewersSettingsView(model: model, settings: model.settings)
                .tabItem { Label("Reviewers", systemImage: "sparkles") }

            DecisionPolicySettingsView(settings: model.settings)
                .tabItem { Label("Decisions", systemImage: "checklist") }

            PromptSettingsView(settings: model.settings)
                .tabItem { Label("Prompt", systemImage: "text.quote") }

            StatisticsView(model: model)
                .tabItem { Label("Statistics", systemImage: "chart.bar.xaxis") }

            HistoryView(model: model, history: model.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .padding(16)
        .task { model.start() }
        .alert(
            "Review Bot couldn't complete that action",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Monitoring") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.configuration.isPaused ? "Monitoring is paused" : model.status)
                                .font(.headline)
                            Text("Run now always performs one check, even while automatic monitoring is paused.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(settings.configuration.isPaused ? "Resume" : "Pause") {
                            model.togglePaused()
                        }
                        .buttonStyle(.bordered)
                        Button("Run now") {
                            model.runNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isPolling)
                    }

                    Divider()

                    HStack {
                        Text("Check for review requests")
                        Picker("Check interval", selection: $settings.configuration.pollIntervalMinutes) {
                            Text("Every 5 minutes").tag(5)
                            Text("Every 15 minutes").tag(15)
                            Text("Every 30 minutes").tag(30)
                            Text("Every 1 hour").tag(60)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Spacer()
                        if let date = model.lastCheckDate {
                            Text("Last checked \(date, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GitHubAccountRow(model: model, settings: settings)

                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(
                            value: $settings.configuration.maxConcurrentReviews,
                            in: 1...8
                        ) {
                            Text(
                                settings.configuration.maxConcurrentReviews == 1
                                    ? "Review one pull request at a time"
                                    : "Review up to \(settings.configuration.maxConcurrentReviews) pull requests at once"
                            )
                        }
                        Text("Each pull request runs every enabled reviewer, so this many times that many CLI processes — and that much API traffic — can be in flight together. Pull requests from the same repository still prepare their worktrees one at a time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Launch Review Bot at login",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    .help("Available after Review Bot is packaged and placed in Applications.")
                }
                .padding(8)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repositories")
                        .font(.title3.weight(.semibold))
                    Text("Review Bot infers the GitHub repository from the folder's origin remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    chooseRepositoryFolder()
                } label: {
                    Label("Add repository", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if settings.configuration.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No repositories", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a local GitHub repository to start watching its review requests.")
                } actions: {
                    Button("Choose folder…") { chooseRepositoryFolder() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($settings.configuration.repositories) { $repository in
                        RepositoryRow(
                            repository: $repository,
                            onDelete: { settings.removeRepository(repository.id) }
                        )
                    }
                    .onDelete(perform: settings.removeRepositories)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 8)
    }

    private func chooseRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a Git repository"
        panel.prompt = "Add Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.addRepository(folder: folder)
    }
}

/// Which of `gh`'s signed-in accounts Review Bot reviews as. Blank means `gh`'s own active
/// account, which is how every install behaved before the setting existed.
private struct GitHubAccountRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    private var configured: String { settings.configuration.githubAccount }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Review as")
                Picker("GitHub account", selection: $settings.configuration.githubAccount) {
                    Text(model.githubAccounts.active.map { "gh's active account (\($0))" } ?? "gh's active account")
                        .tag("")
                    ForEach(model.githubAccounts.accounts, id: \.self) { account in
                        Text(account).tag(account)
                    }
                    // A configured account gh no longer lists stays selectable, so the picker
                    // shows the truth instead of silently reading as "active account".
                    if !configured.isEmpty, !model.githubAccounts.accounts.contains(configured) {
                        Text("\(configured) (not signed in)").tag(configured)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                Button("Refresh accounts") {
                    Task { await model.refreshToolAvailability() }
                }
            }
            Text("Review requests are found, the pull request is fetched, and the review is posted as this account. Sign `gh` in to another with `gh auth login`, then refresh; nothing else on this machine changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !configured.isEmpty, !model.githubAccounts.accounts.contains(configured) {
                Label("gh is not signed in as \(configured); polls will fail until it is.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct RepositoryRow: View {
    @Binding var repository: RepositoryConfiguration
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $repository.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(repository.enabled ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Display name", text: $repository.name)
                    .font(.headline)
                    .textFieldStyle(.plain)
                HStack {
                    Text("GitHub")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    TextField("owner/repository", text: $repository.githubSlug)
                        .font(.caption.monospaced())
                }
                HStack(alignment: .top) {
                    Text("Folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    Text(repository.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this repository from Review Bot")
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            "Remove \(repository.name)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Remove repository", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Review Bot stops watching this repository. Your local files are not affected.")
        }
    }
}

private struct ReviewersSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI reviewers")
                        .font(.title2.weight(.semibold))
                    Text("Enabled reviewers run independently in parallel. The most severe parsed verdict determines the GitHub action.")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Review")
                                .frame(width: 70, alignment: .leading)
                            Picker("Review scope", selection: $settings.configuration.reviewScope) {
                                ForEach(ReviewScope.allCases) { scope in
                                    Text(scope.label).tag(scope)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        Text("“Whole PR” reviews the entire diff every time. “New changes only” reviews just what changed since the last posted review, so reviewers don't re-flag already-reviewed code — it falls back to the whole PR on the first review or a re-request with no new commits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                } label: {
                    Label("Review scope", systemImage: "arrow.left.and.right.text.vertical")
                }

                OptionalLimitBox(
                    title: "Re-review limit",
                    icon: "arrow.clockwise.circle",
                    toggleTitle: "Limit re-reviews per pull request",
                    defaultValue: 3,
                    range: 1...50,
                    stepperTitle: { "Review each pull request up to \($0) time\($0 == 1 ? "" : "s")" },
                    caption: { limit in
                        limit == nil
                            ? "Unlimited: every new commit or re-request is reviewed."
                            : "Counts reviews that were posted. After the limit is reached, further commits and re-requests on that PR are skipped."
                    },
                    limit: $settings.configuration.maxReviewRoundsPerPR
                )

                OptionalLimitBox(
                    title: "Failure budget",
                    icon: "exclamationmark.triangle",
                    toggleTitle: "Give up after repeated failures",
                    defaultValue: 5,
                    range: 1...20,
                    stepperTitle: { "Try a review request up to \($0) time\($0 == 1 ? "" : "s")" },
                    caption: { limit in
                        limit == nil
                            ? "A request whose reviewers keep failing is retried forever, with a widening delay between attempts. Every attempt re-runs the reviewers, so any reviewer billed to your own API key is charged again."
                            : "A review that doesn't post — a reviewer errored, returned no verdict, or GitHub rejected the post — is retried with a widening delay, then abandoned. Every attempt re-runs the reviewers, so any reviewer billed to your own API key is charged again. A new commit, a re-request, or Run now starts over."
                    },
                    limit: Binding(
                        get: { settings.configuration.failureBudget.limit },
                        set: { settings.configuration.failureBudget = FailureBudget(limit: $0) }
                    )
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Include token usage and cost in the posted review",
                            isOn: $settings.configuration.includeUsageInReview
                        )
                        Text("Usage is always recorded in the activity history, whether or not it is posted. Only reviewers billed per token appear — a reviewer using its signed-in CLI is covered by that subscription, so no dollar figure is attributed to it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                } label: {
                    Label("Usage and cost", systemImage: "chart.bar.doc.horizontal")
                }

                ToolStatusRow(
                    name: "GitHub CLI",
                    command: "gh",
                    isAvailable: model.toolAvailability["gh"] == true
                )

                // One card per reviewer, in `ReviewerName` declaration order — the same order
                // `enabledReviewers` uses, so the settings list reads like the posted review.
                ForEach(ReviewerName.allCases) { reviewer in
                    ReviewerCard(
                        model: model,
                        reviewer: reviewer,
                        configuration: configurationBinding(for: reviewer)
                    )
                }

                CustomReviewersSection(model: model, settings: settings)

                HStack {
                    Text("At least one AI reviewer must be enabled. opencode is off by default; it runs the free `opencode/deepseek-v4-flash-free` model at max reasoning effort in a read-only sandbox. DeepSeek is off by default too — it has no CLI, so it needs an API key saved on its card above before it can review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh CLI status") {
                        Task { await model.refreshToolAvailability() }
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func configurationBinding(for reviewer: ReviewerName) -> Binding<ReviewerConfiguration> {
        switch reviewer {
        case .claude: $settings.configuration.claude
        case .codex: $settings.configuration.codex
        case .opencode: $settings.configuration.opencode
        case .deepseek: $settings.configuration.deepseek
        }
    }
}

/// The panel's open end: any number of models reached over an OpenAI-compatible
/// `chat/completions` endpoint, each its own seat in the review.
///
/// One card per model, not per provider — pointing two cards at the same base URL with different
/// model names is exactly how a developer gets two models reading the same pull request.
private struct CustomReviewersSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("More models")
                    .font(.title2.weight(.semibold))
                Text("Add any model reachable over an OpenAI-compatible `chat/completions` endpoint — an aggregator like OpenRouter, a provider's own compatibility endpoint, or a server on your own machine. Each one joins the panel as a full reviewer: it runs the same agent loop in the same read-only sandbox, and its verdict counts like any other.")
                    .foregroundStyle(.secondary)
            }

            ForEach($settings.configuration.customReviewers) { $reviewer in
                CustomReviewerCard(
                    model: model,
                    reviewer: $reviewer,
                    onDelete: { remove(reviewer) }
                )
            }

            HStack {
                Button {
                    settings.configuration.customReviewers.append(CustomReviewerConfiguration())
                } label: {
                    Label("Add a model", systemImage: "plus.circle")
                }
                Spacer()
                Text("Every model you add reads the whole pull request and is billed to its own key, so the panel's cost grows with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Removes the row and the key saved for it. The key is filed under the reviewer's id, so
    /// leaving it behind would orphan a secret in the Keychain that nothing can ever reach
    /// again — there would be no card left to press Remove on.
    private func remove(_ reviewer: CustomReviewerConfiguration) {
        settings.configuration.customReviewers.removeAll { $0.id == reviewer.id }
        Task { await model.removeAPIKey(for: reviewer) }
    }
}

private struct CustomReviewerCard: View {
    @ObservedObject var model: AppModel
    @Binding var reviewer: CustomReviewerConfiguration
    let onDelete: () -> Void

    /// The uniform settings view `PricingRow` works in, written straight back into the row's own
    /// field so the card edits one source of truth.
    ///
    /// Only `pricing` is propagated, because that is the only thing `PricingRow` changes and the
    /// other fields have their own bindings above. Writing them all back would push
    /// `reviewerConfiguration`'s *trimmed* model over the text the developer is typing, so
    /// editing a price would quietly reformat the model field.
    private var configuration: Binding<ReviewerConfiguration> {
        Binding(
            get: { reviewer.reviewerConfiguration },
            set: { reviewer.pricing = $0.pricing }
        )
    }

    private var hasUsableURL: Bool { reviewer.endpointURL != nil }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Enable", isOn: $reviewer.enabled)
                        .font(.headline)
                    Spacer()
                    if model.isCustomReviewerAvailable(reviewer) {
                        Label("HTTP API — key saved", systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            hasUsableURL ? "HTTP API — no key saved" : "Not configured yet",
                            systemImage: "network"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Remove", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                }

                HStack {
                    Text("Name")
                        .frame(width: 70, alignment: .leading)
                    TextField("What to call it in the posted review", text: $reviewer.name)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("API base")
                        .frame(width: 70, alignment: .leading)
                    TextField("https://openrouter.ai/api/v1", text: $reviewer.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .foregroundStyle(
                            reviewer.baseURL.isEmpty || hasUsableURL ? Color.primary : Color.red
                        )
                }

                Text("The API root only — Review Bot appends `chat/completions` itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Model")
                        .frame(width: 70, alignment: .leading)
                    TextField("Model name as the provider spells it", text: $reviewer.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }

                HStack {
                    Text("Time limit")
                        .frame(width: 70, alignment: .leading)
                    Stepper(
                        value: $reviewer.timeoutMinutes,
                        in: ReviewerConfiguration.timeoutMinutesRange
                    ) {
                        Text("\(reviewer.timeoutMinutes) min")
                            .font(.body.monospaced())
                    }
                }

                Text("How long this model may spend on one review before it is cut off. It is billed to your own key, so the limit is also a spend ceiling — and a review that runs out of time contributes nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                APIKeyRow(model: model, custom: reviewer)

                PricingRow(displayName: reviewer.displayName, configuration: configuration)

                if !reviewer.isRunnable {
                    Label(
                        "This model needs a valid API base URL and a model name before it will "
                            + "run. Until then it is skipped rather than failed, so it cannot "
                            + "put an error in every review.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        } label: {
            Label(reviewer.displayName, systemImage: "cpu")
        }
    }
}

/// A "limit this, or don't" setting: a toggle that flips an optional count between
/// off and a default, plus a stepper for the count. Used for the re-review limit and
/// the failure budget, which differ only in their numbers and their prose.
private struct OptionalLimitBox: View {
    let title: String
    let icon: String
    let toggleTitle: String
    let defaultValue: Int
    let range: ClosedRange<Int>
    let stepperTitle: (Int) -> String
    let caption: (Int?) -> String
    @Binding var limit: Int?

    private var isLimited: Binding<Bool> {
        Binding(
            get: { limit != nil },
            set: { limit = $0 ? defaultValue : nil }
        )
    }

    private var count: Binding<Int> {
        Binding(
            get: { limit ?? defaultValue },
            set: { limit = max(range.lowerBound, $0) }
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(toggleTitle, isOn: isLimited)

                if let limit {
                    Stepper(stepperTitle(limit), value: count, in: range)
                }

                Text(caption(limit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

private struct ReviewerCard: View {
    @ObservedObject var model: AppModel
    let reviewer: ReviewerName
    @Binding var configuration: ReviewerConfiguration

    /// Small/experimental models with measurably weaker resistance to injected
    /// thread content (see the prompt-injection spike in issue #3).
    private static let smallModelMarkers = ["mimo", "laguna", "lightning", "big-pickle", "hy3", "mini"]

    /// Says what the number costs, which differs by how the reviewer is billed. A run that is cut
    /// off produces nothing, so the honest advice on a large pull request is "raise it" — but for
    /// a reviewer on your own key the whole window is billable, and that has to be said next to
    /// the control rather than discovered on an invoice.
    private var timeLimitCaption: String {
        let base = "How long \(reviewer.rawValue) may spend on one review before it is cut off. "
            + "A review that runs out of time contributes nothing, so a large pull request may "
            + "need more than the default."
        return configuration.authMode == .apiKey
            ? base + " This reviewer is billed to your own key, so a longer limit is also a "
                + "larger bill for a review that may still not finish."
            : base
    }

    private func isSmallModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return Self.smallModelMarkers.contains { name.contains($0) }
    }

    /// The key rows apply whenever the reviewer is actually billed to a saved key — either the
    /// developer chose that mode, or the reviewer has no session mode to fall back to.
    private var usesSavedKey: Bool {
        reviewer.supportsAPIKeyAuth
            && (configuration.authMode == .apiKey || !reviewer.supportsSessionAuth)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Enable \(reviewer.rawValue)", isOn: $configuration.enabled)
                        .font(.headline)
                    Spacer()
                    if let command = reviewer.commandName {
                        ToolAvailabilityBadge(
                            isAvailable: model.isReviewerAvailable(reviewer),
                            command: command
                        )
                    } else if model.isReviewerAvailable(reviewer) {
                        Label("HTTP API — key saved", systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        // Same question the badge above asks, answered the way it has to be for a
                        // reviewer with no binary to probe: a key is the only thing that makes it
                        // reachable, so saying "no CLI needed" while it cannot run would be a
                        // green light for a reviewer that is about to fail.
                        Label("HTTP API — no key saved", systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Text("Model")
                        .frame(width: 70, alignment: .leading)
                    TextField("Model name", text: $configuration.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                .disabled(!configuration.enabled)

                if reviewer.usesEffortSetting {
                    HStack {
                        Text("Effort")
                            .frame(width: 70, alignment: .leading)
                        Picker("Effort", selection: $configuration.effort) {
                            ForEach(reviewer.efforts) { effort in
                                Text(effort.label).tag(effort)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .disabled(!configuration.enabled)
                }

                HStack {
                    Text("Time limit")
                        .frame(width: 70, alignment: .leading)
                    Stepper(
                        value: $configuration.timeoutMinutes,
                        in: ReviewerConfiguration.timeoutMinutesRange
                    ) {
                        Text("\(configuration.timeoutMinutes) min")
                            .font(.body.monospaced())
                    }
                }
                .disabled(!configuration.enabled)

                Text(timeLimitCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                if reviewer.supportsSessionAuth && reviewer.supportsAPIKeyAuth {
                    HStack {
                        Text("Sign-in")
                            .frame(width: 70, alignment: .leading)
                        Picker("Sign-in", selection: $configuration.authMode) {
                            ForEach(ReviewerAuthMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .disabled(!configuration.enabled)

                    Text(configuration.authMode == .session
                        ? "Uses whatever `\(reviewer.commandName ?? "")` is already logged in as. Review Bot sends no credentials."
                        : "Runs `\(reviewer.commandName ?? "")` with `\(reviewer.apiKeyEnvironmentVariable ?? "")` set from your Keychain, billing that key instead of the CLI's own login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !reviewer.supportsAPIKeyAuth {
                    // No picker to explain itself, so say where the credentials come from.
                    Text("Uses whatever `\(reviewer.commandName ?? "")` is already logged in as. It takes no API key from Review Bot — its provider is chosen in its own configuration — so nothing it spends is billed to a key kept here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if usesSavedKey {
                    APIKeyRow(model: model, reviewer: reviewer)
                        .disabled(!configuration.enabled)

                    if reviewer.needsConfiguredPricing {
                        PricingRow(reviewer: reviewer, configuration: $configuration)
                            .disabled(!configuration.enabled)
                    } else if reviewer.reportsTokenUsage {
                        Label(
                            "\(reviewer.rawValue) reports its own tokens and cost, so there are "
                                + "no prices to configure.",
                            systemImage: "checkmark.seal"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "This CLI does not report token usage, so its cost cannot be tracked.",
                            systemImage: "questionmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if isSmallModel(configuration.model) {
                    Label(
                        "This model is small or experimental: it measurably degrades under adversarial pull-request content, so Review Bot gates its approvals behind injection checks (and never approves when a `VERDICT:` line appears in the thread or diff).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        } label: {
            Label(reviewer.rawValue, systemImage: reviewer.symbolName)
        }
        .onChange(of: configuration.authMode) { _, _ in
            Task { await model.refreshSavedKeys() }
        }
    }
}

/// Prices for providers that report tokens but not cost. Editable because published rates change
/// and a stale built-in number would report the wrong spend without saying so.
private struct PricingRow: View {
    /// What the caption calls this reviewer. A string rather than a `ReviewerName` because a
    /// custom reviewer has no enum case to name it.
    let displayName: String
    /// Rates to offer as a Reset, or `nil` when there is no published default that could be
    /// right — which is every custom endpoint.
    let defaults: TokenPricing?
    @Binding var configuration: ReviewerConfiguration

    init(reviewer: ReviewerName, configuration: Binding<ReviewerConfiguration>) {
        displayName = reviewer.rawValue
        defaults = reviewer.defaultPricing
        _configuration = configuration
    }

    init(
        displayName: String,
        defaults: TokenPricing? = nil,
        configuration: Binding<ReviewerConfiguration>
    ) {
        self.displayName = displayName
        self.defaults = defaults
        _configuration = configuration
    }

    private var pricing: Binding<TokenPricing> {
        Binding(
            // Show what is actually stored. Falling back to the defaults here made an unpriced
            // reviewer look configured while it reported no cost at all.
            get: { configuration.pricing ?? .unpriced },
            set: { configuration.pricing = $0 }
        )
    }

    private var isPriced: Bool {
        !(configuration.pricing ?? .unpriced).isUnpriced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prices")
                    .frame(width: 70, alignment: .leading)
                PriceField(label: "Input", value: pricing.inputPerMillion)
                PriceField(label: "Cached", value: pricing.cachedInputPerMillion)
                PriceField(label: "Output", value: pricing.outputPerMillion)
                // The reviewer's own rates, not DeepSeek's: this row is reached through
                // `needsConfiguredPricing`, which a second such provider would also satisfy —
                // and a custom endpoint has no defaults at all, so it gets no button.
                if let defaults {
                    Button("Reset") { configuration.pricing = defaults }
                        .disabled(configuration.pricing == defaults)
                }
            }

            Text("USD per million tokens, written with a dot or a comma. \(displayName) reports tokens but not cost, so these rates are what turn them into a dollar figure — check them against your provider's current pricing. Set all three to 0 to report tokens only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !isPriced {
                Label(
                    "No rates set, so reviews will report tokens with no cost.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }
}

/// A rate field that keeps its own text so a partially typed value is not clobbered, and that
/// accepts either decimal separator — see `TokenPricing.parseRate`.
private struct PriceField: View {
    let label: String
    @Binding var value: Double
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// True while the field shows something that is not the stored rate, so the field can say
    /// so rather than leave the two silently out of step.
    private var isDraftInvalid: Bool { TokenPricing.parseRate(draft) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .font(.body.monospaced())
                .foregroundStyle(isDraftInvalid ? Color.red : Color.primary)
                .focused($isFocused)
                .onAppear { draft = TokenPricing.renderRate(value) }
                .onChange(of: draft) { _, typed in
                    if let parsed = TokenPricing.parseRate(typed) { value = parsed }
                }
                .onChange(of: value) { _, updated in
                    // Reset and similar external writes need to reach the field, but must not
                    // fight the user mid-keystroke.
                    if TokenPricing.parseRate(draft) != updated {
                        draft = TokenPricing.renderRate(updated)
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    // Text that does not parse never reached `value`, and nothing else would
                    // ever put the two back in step — the re-sync above only fires when `value`
                    // changes, and Reset is disabled while the stored rates are the defaults.
                    // So an abandoned edit snaps back to what is actually stored on the way out.
                    if !focused, isDraftInvalid {
                        draft = TokenPricing.renderRate(value)
                    }
                }
        }
    }
}

private struct APIKeyRow: View {
    @ObservedObject var model: AppModel
    let identity: ReviewerIdentity
    let displayName: String
    @State private var draft = ""

    init(model: AppModel, reviewer: ReviewerName) {
        self.model = model
        identity = .builtIn(reviewer)
        displayName = reviewer.rawValue
    }

    init(model: AppModel, custom: CustomReviewerConfiguration) {
        self.model = model
        identity = custom.identity
        displayName = custom.displayName
    }

    private var hasSavedKey: Bool { model.reviewersWithSavedKey.contains(identity) }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API key")
                    .frame(width: 70, alignment: .leading)
                SecureField(
                    hasSavedKey
                        ? "A key is saved — type a new one to replace it"
                        : "Paste your \(displayName) API key",
                    text: $draft
                )
                .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let key = draft
                    draft = ""
                    Task { await model.saveAPIKey(key, for: identity, named: displayName) }
                }
                .disabled(trimmedDraft.isEmpty)
                Button("Remove", role: .destructive) {
                    Task { await model.removeAPIKey(for: identity, named: displayName) }
                }
                .disabled(!hasSavedKey)
            }

            Label(
                hasSavedKey
                    ? "Saved in your macOS Keychain, never in config.json."
                    : "No key saved. \(displayName) reviews will fail until you add one.",
                systemImage: hasSavedKey ? "key.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(hasSavedKey ? .green : .orange)
        }
    }
}

private struct ToolStatusRow: View {
    let name: String
    let command: String
    let isAvailable: Bool

    var body: some View {
        HStack {
            Label(name, systemImage: "point.3.connected.trianglepath.dotted")
            Spacer()
            ToolAvailabilityBadge(isAvailable: isAvailable, command: command)
        }
        .padding(.horizontal, 12)
    }
}

private struct ToolAvailabilityBadge: View {
    let isAvailable: Bool
    let command: String

    var body: some View {
        Label(
            isAvailable ? "\(command) found" : "\(command) not found",
            systemImage: isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(isAvailable ? .green : .orange)
    }
}

private struct DecisionPolicySettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Decision policy")
                    .font(.title2.weight(.semibold))
                Text("Choose what Review Bot does on GitHub for each severity its reviewers report. When reviewers disagree across the request-changes line, Review Bot reconciles before deciding.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    DecisionRow(
                        verdict: "Blocking",
                        detail: "Always requests changes.",
                        selection: .constant(.requestChanges)
                    )
                    .disabled(true)

                    Divider()

                    DecisionRow(
                        verdict: "Should-fix",
                        detail: "Substantive issues that are not release-blocking.",
                        selection: $settings.configuration.decisionPolicy.shouldFix
                    )
                    DecisionRow(
                        verdict: "Nits only",
                        detail: "Minor, optional suggestions.",
                        selection: $settings.configuration.decisionPolicy.nitsOnly
                    )
                    DecisionRow(
                        verdict: "Clean",
                        detail: "No issues found.",
                        selection: $settings.configuration.decisionPolicy.clean
                    )
                }
                .padding(8)
            } label: {
                Label("When the strictest verdict is…", systemImage: "arrow.triangle.branch")
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("“Leave it to me” posts a neutral comment — no approval and no change request — so you make the call. A reviewer that fails or returns an unreadable verdict always falls back to a neutral comment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to defaults") {
                    settings.configuration.decisionPolicy = .default
                }
                .disabled(settings.configuration.decisionPolicy == .default)
            }

            Spacer()
        }
        .padding(.top, 10)
    }
}

private struct DecisionRow: View {
    let verdict: String
    let detail: String
    @Binding var selection: ReviewDecision

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verdict)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)

            Picker("Action", selection: $selection) {
                ForEach(ReviewDecision.allCases) { decision in
                    Text(decision.actionLabel).tag(decision)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}

private struct PromptSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom review instructions")
                    .font(.title2.weight(.semibold))
                Text("These instructions are appended to Review Bot's built-in review and verdict contract for every repository.")
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $settings.configuration.customPrompt)
                .font(.body.monospaced())
                .padding(8)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

            HStack {
                Text("Examples: project-specific architecture rules, test commands, or areas to scrutinize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(settings.configuration.customPrompt.count) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    settings.configuration.customPrompt = ""
                }
                .disabled(settings.configuration.customPrompt.isEmpty)
            }
        }
        .padding(.top, 10)
    }
}

private struct StatisticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let stats = model.statistics
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review statistics")
                        .font(.title2.weight(.semibold))
                    Text("What Review Bot posted in the last \(stats.windowDays) days, how fast, and whether its change requests were acted on. Computed from the activity history on this Mac.")
                        .foregroundStyle(.secondary)
                }

                StatisticsGroup(title: "Decisions posted") {
                    StatisticTile(title: "Reviews", value: "\(stats.reviewsPosted)", detail: "\(stats.failed) failed")
                    StatisticTile(title: "Approved", value: "\(stats.approved)", tint: .green)
                    StatisticTile(title: "Changes requested", value: "\(stats.changesRequested)", tint: .orange)
                    StatisticTile(title: "Comments", value: "\(stats.commented)", tint: .purple)
                }

                StatisticsGroup(title: "Speed") {
                    StatisticTile(
                        title: "Review duration",
                        value: ReviewStatistics.describe(seconds: stats.averageDurationSeconds),
                        detail: "median \(ReviewStatistics.describe(seconds: stats.medianDurationSeconds)) · last \(ReviewStatistics.describe(seconds: stats.lastDurationSeconds))",
                        help: "From checkout to the posted decision, averaged over the window. Refreshed after every review."
                    )
                    StatisticTile(
                        title: "Response time",
                        value: ReviewStatistics.describe(seconds: stats.averageResponseSeconds),
                        detail: "median \(ReviewStatistics.describe(seconds: stats.medianResponseSeconds))",
                        help: "From the review request on GitHub to the posted decision — includes time spent waiting for a poll and in the queue."
                    )
                }

                StatisticsGroup(title: "Follow-through") {
                    StatisticTile(
                        title: "Change requests acted on",
                        value: ReviewStatistics.describe(rate: stats.changesRequestedThenApprovedRate),
                        detail: "\(stats.changesRequestedThenApproved) of \(stats.pullRequestsWithChangesRequested) pull requests later approved",
                        tint: .orange,
                        help: "A change request counts as acted on when Review Bot later approved the same pull request at a different commit."
                    )
                    StatisticTile(
                        title: "…and merged",
                        value: ReviewStatistics.describe(rate: stats.changesRequestedThenMergedRate),
                        detail: "\(stats.changesRequestedThenMerged) of \(stats.pullRequestsWithChangesRequested) merged after the request",
                        tint: .orange
                    )
                    StatisticTile(
                        title: "Rounds to approval",
                        value: stats.averageRoundsToApproval.map { String(format: "%.2f", $0) } ?? "—",
                        detail: "change requests before an approval followed",
                        help: "1.00 means every change request was resolved in one round."
                    )
                    StatisticTile(
                        title: "Approvals merged",
                        value: ReviewStatistics.describe(rate: stats.approvedThenMergedRate),
                        detail: "\(stats.approvedThenMerged) of \(stats.pullRequestsApproved) approved pull requests",
                        tint: .green
                    )
                }

                StatisticsGroup(title: "Metered spend") {
                    StatisticTile(
                        title: "Tokens",
                        value: TokenUsage.abbreviated(stats.totalTokens),
                        detail: "reviewers billed per token only"
                    )
                    StatisticTile(
                        title: "Cost",
                        value: stats.totalCostUSD.map { String(format: "$%.2f", $0) } ?? (stats.totalTokens > 0 ? "unknown" : "—"),
                        detail: stats.totalCostUSD == nil && stats.totalTokens > 0 ? "a review's cost could not be priced" : ""
                    )
                }

                if stats.reviewsPosted == 0 {
                    Text("No reviews were posted in this window yet. Figures fill in as Review Bot reviews pull requests.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatisticsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                content
            }
        }
    }
}

private struct StatisticTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var tint: Color = .primary
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity history")
                        .font(.title2.weight(.semibold))
                    Text("Review requests, starts, GitHub decisions, and failures are retained locally.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show data folder") { model.revealDataFolder() }
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .disabled(history.entries.isEmpty)
            }

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "clock",
                    description: Text("Events will appear after Review Bot checks your repositories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.entries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 10)
        .confirmationDialog(
            "Clear all activity history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generated review files and detailed logs will remain on disk.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .font(.title3)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.kind.label)
                        .font(.headline)
                    if let number = entry.pullRequestNumber {
                        Text("\(entry.repositoryName) #\(number)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(entry.repositoryName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let title = entry.pullRequestTitle {
                    Text(title)
                        .font(.subheadline)
                }
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let usage = entry.usage {
                    Text(usage.costSummary ?? "\(TokenUsage.abbreviated(usage.totalTokens)) tok")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(usage.tokenSummary) — metered reviewers only")
                }
                if let value = entry.pullRequestURL, let url = URL(string: value) {
                    Link("Open PR", destination: url)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 5)
    }
}
