import Foundation

/// The Windows shell's state and actions: what `AppModel` is to the macOS menu bar, with the
/// dashboard page as its view. It owns the same stores and the same engine, runs the same
/// two-second scheduler, and answers `DashboardBackend` for the page and `trayState` for the
/// icon; the platform calls it needs — opening things, autostart — come through `WindowsShell`.
@MainActor
final class WindowsAppModel: DashboardBackend {
    private(set) var status = "Starting…"
    private(set) var isRunning = false
    private(set) var lastCheckDate: Date?
    private(set) var toolAvailability: [String: Bool] = [:]
    private(set) var reviewersWithSavedKey: Set<ReviewerName> = []
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
            isRunning: isRunning,
            lastCheckDate: lastCheckDate,
            toolAvailability: toolAvailability,
            reviewersWithSavedKey: ReviewerName.allCases.filter { reviewersWithSavedKey.contains($0) },
            launchAtLoginEnabled: WindowsShell.LaunchAtLogin.isEnabled,
            pendingReviews: pendingReviews,
            runningReviews: runningReviews,
            errorMessage: message,
            configuration: settings.configuration,
            configurationVersion: configurationVersion,
            historyCount: history.entries.count,
            lastEventKind: history.entries.first?.kind,
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
        settings.configuration = configuration
        configurationChanged()
        if authModesChanged {
            await refreshSavedKeys()
        }
        return configurationVersion
    }

    func runNow() {
        guard !isRunning else { return }
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

    func saveAPIKey(_ key: String, for reviewer: ReviewerName) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.setAPIKey(trimmed, for: reviewer)
        }
        if let failure = outcome.failure {
            report("Could not save the \(reviewer.rawValue) API key: \(failure)")
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        if outcome.effective == nil {
            status = "Saved the \(reviewer.rawValue) API key, but it could not be read back"
        } else if outcome.effective != trimmed {
            // The environment takes precedence over the Credential Manager, so a variable set
            // in this app's environment would shadow the key that was just saved. Say so rather
            // than report a save that will not be the one used.
            status = """
            Saved the \(reviewer.rawValue) API key, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is set in this app's environment \
            and takes precedence over it
            """
        } else {
            status = "Saved the \(reviewer.rawValue) API key to the Windows Credential Manager"
        }
        changed()
    }

    func removeAPIKey(for reviewer: ReviewerName) async {
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.removeAPIKey(for: reviewer)
        }
        if let failure = outcome.failure {
            report("Could not remove the \(reviewer.rawValue) API key: \(failure)")
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        if outcome.effective != nil {
            status = """
            Removed the \(reviewer.rawValue) API key, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is still set in this app's \
            environment and will be used
            """
        } else {
            status = "Removed the \(reviewer.rawValue) API key from the Windows Credential Manager"
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
        await refreshSavedKeys()
        changed()
    }

    func refreshSavedKeys() async {
        let resolved = await ResolvedCredentials.resolve(
            ReviewerName.allCases.filter { reviewer in
                reviewer.supportsAPIKeyAuth
                    && settings.configuration.settings(for: reviewer).authMode == .apiKey
            },
            from: credentials
        )
        reviewersWithSavedKey = resolved.reviewersWithKey
    }

    private struct CredentialWriteOutcome: Sendable {
        var effective: String?
        var failure: String?
    }

    private func performCredentialWrite(
        for reviewer: ReviewerName,
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

    private func updateSavedKeyPanel(_ outcome: CredentialWriteOutcome, for reviewer: ReviewerName) {
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
                if pollIsDue, !isRunning {
                    await performPoll()
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func performPoll(manual: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        changed()
        defer {
            isRunning = false
            lastCheckDate = Date()
            // A poll reviews every request it discovers before returning, so nothing should
            // remain queued afterward. Reset defensively so a missed or out-of-order terminal
            // event can never leave a stale count on the page.
            pendingReviews.removeAll()
            runningReviews.removeAll()
            changed()
        }

        let configuration = settings.configuration
        await engine.poll(
            configuration: configuration,
            manual: manual,
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
        }
    }
}
