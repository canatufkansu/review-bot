import Foundation

/// The Windows shell's state and actions: what `AppModel` is to the macOS menu bar, with the
/// dashboard page as its view. It owns the same stores and the same engine, runs the same
/// two-second scheduler, and answers `DashboardBackend` for the page and `trayState` for the
/// icon; the platform calls it needs — opening things, autostart — come through `WindowsShell`.
@MainActor
final class WindowsAppModel: DashboardBackend {
    private(set) var status = "Starting…"
    /// A discovery pass is in progress. Reviews outlive it — see `isRunning`.
    private(set) var isPolling = false
    /// Whether Review Bot is doing anything: discovering requests or reviewing one.
    var isRunning: Bool { isPolling || !runningReviews.isEmpty }
    private(set) var lastCheckDate: Date?
    private(set) var toolAvailability: [String: Bool] = [:]
    private(set) var githubAccounts: GitHubAccounts = .none
    /// Panel seats a key currently resolves for, built-in and custom alike.
    private(set) var reviewersWithSavedKey: Set<ReviewerIdentity> = []
    private(set) var pendingReviews: [ReviewQueueItem] = []
    /// Every review running right now — a poll reviews several pull requests at once.
    private(set) var runningReviews: [ReviewQueueItem] = []
    /// Shown once by the page, then cleared — the equivalent of the macOS alert.
    private var errorMessage: String?
    /// Bumped on every configuration change so the page knows when to re-render its forms.
    private(set) var configurationVersion = 1

    let settings: SettingsStore
    let history: HistoryStore
    let paths: StoragePaths

    private let runner: any CommandRunning
    private let credentials: any CredentialStoring
    private let engine: ReviewEngine
    private var schedulerTask: Task<Void, Never>?
    private var hasStarted = false
    private var quitContinuation: CheckedContinuation<Void, Never>?

    /// Where the dashboard lives once the server is up; `nil` if it failed to start.
    var dashboardURL: String?
    /// Called after every state change, so the tray can redraw.
    var onStateChange: (@MainActor () -> Void)?

    init(
        paths: StoragePaths = StoragePaths(),
        credentials: any CredentialStoring = WindowsCredentialStore()
    ) {
        self.paths = paths
        self.credentials = credentials
        runner = ProcessRunner()
        settings = SettingsStore(paths: paths)
        history = HistoryStore(paths: paths)
        engine = ReviewEngine(paths: paths, runner: runner, credentials: credentials)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        schedulerTask = Task { [weak self] in
            guard let self else { return }
            await refreshToolAvailability()
            await schedulerLoop()
        }
    }

    /// Suspends until `quit()` is called from the tray or the page.
    func waitForQuit() async {
        await withCheckedContinuation { continuation in
            quitContinuation = continuation
        }
    }

    var trayState: TrayState {
        TrayState(
            status: status,
            isPaused: settings.configuration.isPaused,
            isPolling: isPolling,
            isRunning: isRunning,
            hasFailure: history.entries.first?.kind == .failed
        )
    }

    func perform(_ action: TrayAction) {
        switch action {
        case .openDashboard: openDashboard()
        case .runNow: runNow()
        case .togglePaused: togglePausedNow()
        case .openDataFolder: openDataFolderNow()
        case .quit: quitNow()
        }
    }

    func openDashboard() {
        guard let dashboardURL else {
            report("The dashboard server did not start, so there is no page to open. Check the log for details.")
            return
        }
        WindowsShell.open(dashboardURL)
    }

    func report(_ message: String) {
        errorMessage = message
        Task { await ActivityLogger(directory: paths.logsDirectory).append("Windows shell: \(message)") }
        changed()
    }

    private func changed() {
        onStateChange?()
    }

    private func configurationChanged() {
        configurationVersion += 1
        changed()
    }

    // MARK: - DashboardBackend

    func snapshot() -> DashboardSnapshot {
        let message = errorMessage
        errorMessage = nil
        return DashboardSnapshot(
            status: status,
            isPolling: isPolling,
            isRunning: isRunning,
            lastCheckDate: lastCheckDate,
            toolAvailability: toolAvailability,
            githubAccounts: githubAccounts,
            // Ordered the way the panel is — built-ins first, then the custom rows as
            // configured — so the page never has to sort them.
            reviewersWithSavedKey: (
                ReviewerName.allCases.map(ReviewerIdentity.builtIn)
                    + settings.configuration.customReviewers.map(\.identity)
            )
            .filter { reviewersWithSavedKey.contains($0) }
            .map(\.wireIdentifier),
            launchAtLoginEnabled: WindowsShell.LaunchAtLogin.isEnabled,
            pendingReviews: pendingReviews,
            runningReviews: runningReviews,
            errorMessage: message,
            configuration: settings.configuration,
            configurationVersion: configurationVersion,
            historyCount: history.entries.count,
            lastEventKind: history.entries.first?.kind,
            statistics: ReviewStatistics.compute(from: history.entries),
            dataFolder: WindowsShell.nativePath(paths.root),
            version: WindowsShell.version,
            reviewers: ReviewerDescriptor.all
        )
    }

    func historyEntries() -> [HistoryEntry] {
        history.entries
    }

    func replaceConfiguration(_ configuration: ReviewBotConfiguration) async -> Int {
        let authModesChanged = ReviewerName.allCases.contains {
            settings.configuration.settings(for: $0).authMode != configuration.settings(for: $0).authMode
        }
        // A custom reviewer added or removed changes which keys have to be resolved just as an
        // auth-mode flip does, and the badges on its card read that resolution.
        let customReviewersChanged = settings.configuration.customReviewers.map(\.id)
            != configuration.customReviewers.map(\.id)
        settings.configuration = configuration
        configurationChanged()
        if authModesChanged || customReviewersChanged {
            await refreshSavedKeys()
        }
        return configurationVersion
    }

    func runNow() {
        guard !isPolling else { return }
        Task { [weak self] in
            await self?.performPoll(manual: true)
        }
    }

    func togglePaused() {
        togglePausedNow()
    }

    private func togglePausedNow() {
        settings.configuration.isPaused.toggle()
        status = settings.configuration.isPaused ? "Monitoring paused" : "Monitoring resumed"
        configurationChanged()
        if !settings.configuration.isPaused, lastCheckDate == nil {
            runNow()
        }
    }

    func addRepository(folder: String) async throws {
        let repository = try await RepositoryInspector(runner: runner)
            .inspect(folder: URL(fileURLWithPath: folder))
        settings.add(repository)
        status = "Added \(repository.name)"
        configurationChanged()
    }

    func removeRepository(id: UUID) {
        settings.removeRepository(id)
        configurationChanged()
    }

    /// What to call a panel seat in a status line. A custom reviewer's name comes from its row;
    /// a row that has since been deleted falls back to its id so the message still identifies
    /// something rather than going blank.
    private func displayName(for reviewer: ReviewerIdentity) -> String {
        switch reviewer {
        case let .builtIn(name):
            return name.rawValue
        case let .custom(id):
            return settings.configuration.customReviewers
                .first { $0.id == id }?
                .displayName
                ?? id.uuidString
        }
    }

    func saveAPIKey(_ key: String, for reviewer: ReviewerIdentity) async {
        let name = displayName(for: reviewer)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.setAPIKey(trimmed, for: reviewer)
        }
        if let failure = outcome.failure {
            report("Could not save the \(name) API key: \(failure)")
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        if outcome.effective == nil {
            status = "Saved the \(name) API key, but it could not be read back"
        } else if outcome.effective != trimmed {
            // The environment takes precedence over the Credential Manager, so a variable set
            // in this app's environment would shadow the key that was just saved. Say so rather
            // than report a save that will not be the one used.
            status = """
            Saved the \(name) API key, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is set in this app's environment \
            and takes precedence over it
            """
        } else {
            status = "Saved the \(name) API key to the Windows Credential Manager"
        }
        changed()
    }

    func removeAPIKey(for reviewer: ReviewerIdentity) async {
        let name = displayName(for: reviewer)
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.removeAPIKey(for: reviewer)
        }
        if let failure = outcome.failure {
            report("Could not remove the \(name) API key: \(failure)")
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        if outcome.effective != nil {
            status = """
            Removed the \(name) API key, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is still set in this app's \
            environment and will be used
            """
        } else {
            status = "Removed the \(name) API key from the Windows Credential Manager"
        }
        changed()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try WindowsShell.LaunchAtLogin.set(enabled)
        } catch {
            report(error.localizedDescription)
        }
    }

    func clearHistory() {
        history.clear()
        changed()
    }

    func openDataFolder() {
        openDataFolderNow()
    }

    private func openDataFolderNow() {
        try? paths.prepare()
        WindowsShell.open(WindowsShell.nativePath(paths.root))
    }

    func quit() {
        quitNow()
    }

    private func quitNow() {
        schedulerTask?.cancel()
        quitContinuation?.resume()
        quitContinuation = nil
    }

    // MARK: - Tools and keys

    func refreshToolAvailability() async {
        var statuses: [String: Bool] = [:]
        // Derived from the reviewers rather than written out, so a reviewer added to
        // `ReviewerName` is checked without a second edit here. DeepSeek has no `commandName`
        // and is skipped: its readiness is a question about credentials, answered below.
        for tool in ["gh"] + ReviewerName.allCases.compactMap(\.commandName) {
            statuses[tool] = PlatformProcess.locate(tool) != nil
        }
        toolAvailability = statuses
        if let result = try? await runner.run("gh", arguments: ["auth", "status"], timeout: 20) {
            githubAccounts = GitHubAccounts.parse(result.stdout + "\n" + result.stderr)
        }
        await refreshSavedKeys()
        changed()
    }

    func refreshSavedKeys() async {
        let builtIn = ReviewerName.allCases
            .filter { reviewer in
                reviewer.supportsAPIKeyAuth
                    && settings.configuration.settings(for: reviewer).authMode == .apiKey
            }
            .map(ReviewerIdentity.builtIn)
        // Every custom reviewer is an HTTP endpoint, so all of them are key-mode by
        // construction — there is no session alternative to skip for.
        let custom = settings.configuration.customReviewers.map(\.identity)
        let resolved = await ResolvedCredentials.resolve(builtIn + custom, from: credentials)
        reviewersWithSavedKey = resolved.reviewersWithKey
    }

    private struct CredentialWriteOutcome: Sendable {
        var effective: String?
        var failure: String?
    }

    private func performCredentialWrite(
        for reviewer: ReviewerIdentity,
        _ body: @escaping @Sendable (any CredentialStoring) throws -> Void
    ) async -> CredentialWriteOutcome {
        let store = credentials
        return await Task.detached(priority: .userInitiated) {
            do {
                try body(store)
                return CredentialWriteOutcome(effective: store.apiKey(for: reviewer))
            } catch {
                return CredentialWriteOutcome(failure: error.localizedDescription)
            }
        }.value
    }

    private func updateSavedKeyPanel(
        _ outcome: CredentialWriteOutcome,
        for reviewer: ReviewerIdentity
    ) {
        if outcome.effective == nil {
            reviewersWithSavedKey.remove(reviewer)
        } else {
            reviewersWithSavedKey.insert(reviewer)
        }
    }

    // MARK: - Scheduler

    private func schedulerLoop() async {
        while !Task.isCancelled {
            if settings.configuration.isPaused {
                if !isRunning, status != "Monitoring paused" {
                    status = "Monitoring paused"
                    changed()
                }
            } else {
                let interval = TimeInterval(max(1, settings.configuration.pollIntervalMinutes) * 60)
                let pollIsDue = lastCheckDate.map { Date().timeIntervalSince($0) >= interval } ?? true
                // Polling is gated on discovery alone, not on the reviews: they keep running
                // behind the poll, and a poll that finds a new request while they do simply
                // queues it behind them.
                if pollIsDue, !isPolling {
                    await performPoll()
                }
            }
            await reconcileQueueWithEngine()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Nothing should be shown as queued or running once the engine's queue is empty. Reset
    /// defensively so a missed or out-of-order terminal event can never leave a stale count
    /// on the page.
    private func reconcileQueueWithEngine() async {
        guard !pendingReviews.isEmpty || !runningReviews.isEmpty else { return }
        if await engine.isIdle() {
            pendingReviews.removeAll()
            runningReviews.removeAll()
            changed()
        }
    }

    private func performPoll(manual: Bool = false) async {
        guard !isPolling else { return }
        isPolling = true
        changed()
        defer {
            isPolling = false
            lastCheckDate = Date()
            changed()
        }

        let configuration = settings.configuration
        // Returns once discovery is done; the reviews it queued carry on and report through
        // the same sinks.
        await engine.poll(
            configuration: configuration,
            manual: manual,
            awaitCompletion: false,
            onEvent: { [weak self] entry in
                await MainActor.run {
                    self?.history.append(entry)
                    self?.updateQueue(for: entry)
                    self?.changed()
                }
            },
            onStatus: { [weak self] value in
                await MainActor.run {
                    self?.status = value
                    self?.changed()
                }
            }
        )
    }

    private func updateQueue(for entry: HistoryEntry) {
        guard let item = ReviewQueueItem(entry: entry) else { return }
        switch entry.kind {
        case .requestDetected:
            pendingReviews.removeAll(where: { $0.id == item.id })
            pendingReviews.append(item)
        case .reviewStarted:
            pendingReviews.removeAll(where: { $0.id == item.id })
            runningReviews.removeAll(where: { $0.id == item.id })
            runningReviews.append(item)
        case .approved, .changesRequested, .commented, .failed:
            pendingReviews.removeAll(where: { $0.id == item.id })
            runningReviews.removeAll(where: { $0.id == item.id })
        case .merged:
            break
        }
    }
}
