import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status = "Starting…"
    /// A discovery pass is in progress. Reviews outlive it — see `isRunning`.
    @Published private(set) var isPolling = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var toolAvailability: [String: Bool] = [:]
    /// The GitHub accounts `gh` is signed in to, for the account picker.
    @Published private(set) var githubAccounts: GitHubAccounts = .none
    /// Panel seats a key currently resolves for, built-in and custom alike — which is why it
    /// is keyed by identity rather than by `ReviewerName`.
    @Published private(set) var reviewersWithSavedKey: Set<ReviewerIdentity> = []
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var pendingReviews: [ReviewQueueItem] = []
    /// Every review running right now — a poll reviews several pull requests at once,
    /// so this is a list. It was a single optional while polls were sequential, which
    /// meant the second review to start erased the first from the menu bar even though
    /// it was still running.
    @Published private(set) var runningReviews: [ReviewQueueItem] = []
    @Published var errorMessage: String?
    /// Refreshed from the history after every event, so the figures in the menu bar and
    /// the Statistics tab move the moment a review posts.
    @Published private(set) var statistics: ReviewStatistics = .empty

    /// Whether Review Bot is doing anything: discovering requests or reviewing one. The
    /// two are separate now that a poll returns as soon as discovery is done and the
    /// reviews run on behind it.
    var isRunning: Bool { isPolling || !runningReviews.isEmpty }

    let settings: SettingsStore
    let history: HistoryStore

    private let paths: StoragePaths
    private let runner: any CommandRunning
    private let credentials: any CredentialStoring
    private let engine: ReviewEngine
    private var schedulerTask: Task<Void, Never>?
    private var settingsWindowController: NSWindowController?
    private var hasStarted = false

    init(
        paths: StoragePaths = StoragePaths(),
        credentials: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.paths = paths
        self.credentials = credentials
        runner = ProcessRunner()
        settings = SettingsStore(paths: paths)
        history = HistoryStore(paths: paths)
        engine = ReviewEngine(paths: paths, runner: runner, credentials: credentials)
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        statistics = ReviewStatistics.compute(from: history.entries)
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

    func runNow() {
        guard !isPolling else { return }
        Task { [weak self] in
            await self?.performPoll(manual: true)
        }
    }

    func clearHistory() {
        history.clear()
        statistics = ReviewStatistics.compute(from: history.entries)
    }

    func togglePaused() {
        settings.configuration.isPaused.toggle()
        status = settings.configuration.isPaused ? "Monitoring paused" : "Monitoring resumed"
        if !settings.configuration.isPaused, lastCheckDate == nil {
            runNow()
        }
    }

    func addRepository(folder: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let repository = try await RepositoryInspector(runner: runner).inspect(folder: folder)
                settings.add(repository)
                status = "Added \(repository.name)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshToolAvailability() async {
        var statuses: [String: Bool] = [:]
        // The probe list is derived from the reviewers rather than written out, so a reviewer
        // added to `ReviewerName` is checked without a second edit here. DeepSeek has no
        // `commandName` and so is skipped: there is no binary to find, and its readiness is a
        // question about credentials, which `refreshSavedKeys` answers below.
        for tool in ["gh"] + ReviewerName.allCases.compactMap(\.commandName) {
            let result = try? await runner.run("which", arguments: [tool], timeout: 10)
            statuses[tool] = result?.succeeded == true
        }
        toolAvailability = statuses
        githubAccounts = await Self.discoverGitHubAccounts(runner: runner)
        await refreshSavedKeys()
    }

    /// `gh auth status` lists every signed-in account; it exits non-zero when any of them is
    /// broken, so the output is parsed whatever the exit code, and read from both streams —
    /// older `gh` versions print it to stderr.
    static func discoverGitHubAccounts(runner: any CommandRunning) async -> GitHubAccounts {
        guard let result = try? await runner.run("gh", arguments: ["auth", "status"], timeout: 20) else {
            return .none
        }
        return GitHubAccounts.parse(result.stdout + "\n" + result.stderr)
    }

    /// Whether a reviewer could run right now.
    ///
    /// A CLI-backed reviewer needs its binary on `PATH`; DeepSeek is reached over HTTP, so the
    /// equivalent question is whether a key resolves for it — from this app's environment or the
    /// Keychain. Answering both through one call keeps the UI from having to know which reviewers
    /// are processes and which are endpoints.
    func isReviewerAvailable(_ reviewer: ReviewerName) -> Bool {
        guard let command = reviewer.commandName else {
            return reviewersWithSavedKey.contains(.builtIn(reviewer))
        }
        return toolAvailability[command] == true
    }

    /// A custom reviewer is an endpoint, not a process, so the only question is whether it is
    /// fully configured and a key resolves for it.
    func isCustomReviewerAvailable(_ reviewer: CustomReviewerConfiguration) -> Bool {
        reviewer.isRunnable && reviewersWithSavedKey.contains(reviewer.identity)
    }

    /// Which reviewers have a key available — from the Keychain, or from the environment, which
    /// takes precedence over it.
    ///
    /// Only reviewers actually configured for key auth are looked up: reading a Keychain item
    /// can prompt for access on an ad-hoc-signed build, and a developer using signed-in CLIs
    /// should never see that prompt. An environment-supplied key is answered without touching
    /// the Keychain at all, so it cannot prompt.
    ///
    /// The read happens off the main actor, which is why this is `async`. A Keychain prompt
    /// blocks the thread that raises it until the user answers, and blocking this one freezes
    /// the settings window that is asking the question.
    func refreshSavedKeys() async {
        let builtIn = ReviewerName.allCases
            .filter { reviewer in
                reviewer.supportsAPIKeyAuth
                    && settings.configuration.settings(for: reviewer).authMode == .apiKey
            }
            .map(ReviewerIdentity.builtIn)
        // Every custom reviewer is an HTTP endpoint, so all of them are key-mode by
        // construction. Unlike the built-ins there is no session alternative to skip for.
        let custom = settings.configuration.customReviewers.map(\.identity)
        let resolved = await ResolvedCredentials.resolve(builtIn + custom, from: credentials)
        reviewersWithSavedKey = resolved.reviewersWithKey
    }

    /// What a Keychain write left in effect, read back on the same detached task that performed
    /// the write so the panel and the status line can never disagree about it.
    private struct CredentialWriteOutcome: Sendable {
        var effective: String?
        var failure: String?
    }

    func saveAPIKey(_ key: String, for reviewer: ReviewerName) async {
        await saveAPIKey(key, for: .builtIn(reviewer), named: reviewer.rawValue)
    }

    func saveAPIKey(_ key: String, for reviewer: CustomReviewerConfiguration) async {
        await saveAPIKey(key, for: reviewer.identity, named: reviewer.displayName)
    }

    func saveAPIKey(
        _ key: String,
        for reviewer: ReviewerIdentity,
        named displayName: String
    ) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.setAPIKey(trimmed, for: reviewer)
        }
        if let failure = outcome.failure {
            errorMessage = "Could not save the \(displayName) API key: \(failure)"
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        if outcome.effective == nil {
            // The write succeeded but reading it back did not, which on an ad-hoc-signed build
            // means the Keychain prompt was denied. Reporting a plain "Saved" here would leave
            // the panel below saying no key is saved, and the next review failing for a reason
            // nothing on screen explained.
            status = """
            Saved the \(displayName) API key, but it could not be read back — allow \
            Review Bot access when macOS asks, or \(displayName) reviews will fail
            """
        } else if outcome.effective != trimmed {
            // The environment takes precedence over the Keychain, so a variable left over in
            // this app's environment would shadow the key that was just saved. Say so rather
            // than report a save that will not be the one used.
            status = """
            Saved the \(displayName) API key, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is set in this app's environment \
            and takes precedence over it
            """
        } else {
            status = "Saved the \(displayName) API key to your Keychain"
        }
    }

    func removeAPIKey(for reviewer: ReviewerName) async {
        await removeAPIKey(for: .builtIn(reviewer), named: reviewer.rawValue)
    }

    func removeAPIKey(for reviewer: CustomReviewerConfiguration) async {
        await removeAPIKey(for: reviewer.identity, named: reviewer.displayName)
    }

    func removeAPIKey(for reviewer: ReviewerIdentity, named displayName: String) async {
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.removeAPIKey(for: reviewer)
        }
        if let failure = outcome.failure {
            errorMessage = "Could not remove the \(displayName) API key: \(failure)"
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        // A key that still resolves after removal can only be coming from the environment,
        // and reporting a bare "Removed" would imply the reviewer had stopped being billed.
        if outcome.effective != nil {
            status = """
            Removed the \(displayName) API key from your Keychain, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is still set in this app's \
            environment and will be used
            """
        } else {
            status = "Removed the \(displayName) API key from your Keychain"
        }
    }

    /// Performs one Keychain write off the main actor and reads back what it left in effect.
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

    /// Updates the panel from the write's own read-back rather than a second Keychain round
    /// trip, so a denied read cannot make the status line and the panel tell different stories.
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

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    func revealDataFolder() {
        try? paths.prepare()
        NSWorkspace.shared.activateFileViewerSelecting([paths.root])
    }

    func openSettings() {
        let controller: NSWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            let hostingController = NSHostingController(rootView: DashboardView(model: self))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Review Bot Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 800, height: 620))
            window.minSize = NSSize(width: 760, height: 560)
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ReviewBotSettingsWindow")

            controller = NSWindowController(window: window)
            settingsWindowController = controller

            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoreAccessoryActivationPolicy()
                }
            }
        }

        // Review Bot runs as a menu-bar accessory (LSUIElement), so it must be promoted
        // to a regular app before AppKit will bring a standard window forward or make it key.
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func restoreAccessoryActivationPolicy() {
        NSApp.setActivationPolicy(.accessory)
    }

    var statusSymbol: String {
        if isRunning { return "arrow.triangle.2.circlepath" }
        if settings.configuration.isPaused { return "pause.circle.fill" }
        if history.entries.first?.kind == .failed { return "exclamationmark.circle.fill" }
        return "checkmark.bubble.fill"
    }

    private func schedulerLoop() async {
        while !Task.isCancelled {
            if settings.configuration.isPaused {
                if !isRunning { status = "Monitoring paused" }
            } else {
                let interval = TimeInterval(max(1, settings.configuration.pollIntervalMinutes) * 60)
                let pollIsDue = lastCheckDate.map { Date().timeIntervalSince($0) >= interval } ?? true
                // Polling is gated on discovery alone, not on the reviews: they keep
                // running behind the poll, and a poll that finds a new request while
                // they do simply queues it behind them.
                if pollIsDue, !isPolling {
                    await performPoll()
                }
            }
            await reconcileQueueWithEngine()

            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Nothing should be shown as queued or running once the engine's queue is empty.
    /// Reset defensively so a missed or out-of-order terminal event can never leave a
    /// stale count in the menu bar.
    private func reconcileQueueWithEngine() async {
        guard !pendingReviews.isEmpty || !runningReviews.isEmpty else { return }
        if await engine.isIdle() {
            pendingReviews.removeAll()
            runningReviews.removeAll()
        }
    }

    private func performPoll(manual: Bool = false) async {
        guard !isPolling else { return }
        isPolling = true
        defer {
            isPolling = false
            lastCheckDate = Date()
        }

        let configuration = settings.configuration
        // Returns once discovery is done; the reviews it queued carry on and report
        // through the same sinks.
        await engine.poll(
            configuration: configuration,
            manual: manual,
            awaitCompletion: false,
            onEvent: { [weak self] entry in
                await MainActor.run {
                    guard let self else { return }
                    self.history.append(entry)
                    self.updateQueue(for: entry)
                    if entry.kind.endsAReview || entry.kind == .merged {
                        self.statistics = ReviewStatistics.compute(from: self.history.entries)
                    }
                }
            },
            onStatus: { [weak self] value in
                await MainActor.run {
                    self?.status = value
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
