import Foundation

/// Everything the dashboard page shows, in one document. Fetched every couple of seconds, so
/// it is kept to what changes; the history list has its own route.
struct DashboardSnapshot: Codable {
    var status: String
    var isRunning: Bool
    var lastCheckDate: Date?
    var toolAvailability: [String: Bool]
    /// The accounts `gh` is signed in to, for the account picker.
    var githubAccounts: GitHubAccounts
    var reviewersWithSavedKey: [ReviewerName]
    var launchAtLoginEnabled: Bool
    var pendingReviews: [ReviewQueueItem]
    /// Every review in flight: a poll reviews several pull requests at once.
    var runningReviews: [ReviewQueueItem]
    /// The latest failure the shell wants shown, cleared once the page has fetched it.
    var errorMessage: String?
    var configuration: ReviewBotConfiguration
    /// Bumped on every configuration save. The page re-renders its forms only when this moves
    /// past what it last wrote, so a poll never overwrites a field being typed into.
    var configurationVersion: Int
    var historyCount: Int
    /// The kind of the newest history entry, which is what colours the status: a failure at the
    /// top of the list is what turns the icon red.
    var lastEventKind: HistoryEventKind?
    var dataFolder: String
    var version: String
    var reviewers: [ReviewerDescriptor]
}

/// The per-reviewer facts the page needs to draw a card, so the reviewer surface — which
/// reviewer takes a key, which has efforts, which needs prices — stays defined once, in
/// `ReviewerName`, and is never restated in JavaScript.
struct ReviewerDescriptor: Codable {
    var name: ReviewerName
    var commandName: String?
    var supportsSessionAuth: Bool
    var supportsAPIKeyAuth: Bool
    var usesEffortSetting: Bool
    var efforts: [EffortOption]
    var reportsTokenUsage: Bool
    var needsConfiguredPricing: Bool
    var defaultPricing: TokenPricing?
    var apiKeyEnvironmentVariable: String?

    struct EffortOption: Codable {
        var value: ReviewEffort
        var label: String
    }

    init(_ reviewer: ReviewerName) {
        name = reviewer
        commandName = reviewer.commandName
        supportsSessionAuth = reviewer.supportsSessionAuth
        supportsAPIKeyAuth = reviewer.supportsAPIKeyAuth
        usesEffortSetting = reviewer.usesEffortSetting
        efforts = reviewer.efforts.map { EffortOption(value: $0, label: $0.label) }
        reportsTokenUsage = reviewer.reportsTokenUsage
        needsConfiguredPricing = reviewer.needsConfiguredPricing
        defaultPricing = reviewer.defaultPricing
        apiKeyEnvironmentVariable = reviewer.apiKeyEnvironmentVariable
    }

    static let all = ReviewerName.allCases.map(ReviewerDescriptor.init)
}

/// What the shell behind the dashboard can do. `WindowsAppModel` is the production
/// implementation; a test can stand in a fake and drive the routes without a tray or an engine.
protocol DashboardBackend: AnyObject {
    func snapshot() async -> DashboardSnapshot
    func historyEntries() async -> [HistoryEntry]
    /// Replaces the configuration wholesale. Returns the new configuration version.
    func replaceConfiguration(_ configuration: ReviewBotConfiguration) async -> Int
    func runNow() async
    func togglePaused() async
    func addRepository(folder: String) async throws
    func removeRepository(id: UUID) async
    func saveAPIKey(_ key: String, for reviewer: ReviewerName) async
    func removeAPIKey(for reviewer: ReviewerName) async
    func setLaunchAtLogin(_ enabled: Bool) async
    func clearHistory() async
    func refreshToolAvailability() async
    func openDataFolder() async
    func quit() async
}

/// The dashboard's routes: one HTML page and a JSON API under `/api/`.
///
/// Every API call must carry the launch token as a bearer header and a `Host` naming this
/// server. The page gets the token from the URL the tray opened (`/?t=…`) and keeps it in
/// memory; nothing else on the machine is told it. A page on some other origin cannot send the
/// header without a CORS preflight this server never answers, and cannot read a response even
/// if it could send a request — so a malicious site open in the same browser gets nothing
/// from a Review Bot that happens to be running.
final class DashboardAPI: @unchecked Sendable {
    private let backend: any DashboardBackend
    private let token: String
    private let page: String

    init(backend: any DashboardBackend, token: String, page: String = DashboardPage.html) {
        self.backend = backend
        self.token = token
        self.page = page
    }

    /// The URL the tray opens: the page, with the token it needs to talk to the API.
    static func dashboardURL(port: UInt16, token: String) -> String {
        "http://127.0.0.1:\(port)/?t=\(token)"
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let segments = request.pathSegments

        if segments.isEmpty {
            guard request.method == "GET" else { return .error(405, "method not allowed") }
            return .html(page)
        }
        guard segments.first == "api" else { return .error(404, "not found") }

        guard isAuthorized(request) else {
            return .error(401, "missing or invalid dashboard token")
        }

        do {
            return try await route(request, Array(segments.dropFirst()))
        } catch let error as RouteError {
            return .error(error.status, error.message)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let host = request.headers["host"],
              host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:") else {
            return false
        }
        guard let authorization = request.headers["authorization"] else { return false }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return false }
        // Constant-time comparison is not needed for a per-launch token that never leaves this
        // machine, but there is no reason to make the mismatch position observable either.
        let presented = Array(authorization.dropFirst(prefix.count).utf8)
        let expected = Array(token.utf8)
        guard presented.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(presented, expected) { difference |= a ^ b }
        return difference == 0
    }

    private struct RouteError: Error {
        var status: Int
        var message: String
    }

    /// Whether `segments` is `pattern` — same length, each segment equal to the pattern's, with
    /// `nil` in the pattern standing for any one segment (an id, a reviewer name).
    private func matches(
        _ request: HTTPRequest,
        _ segments: [String],
        _ method: String,
        _ pattern: [String?]
    ) -> Bool {
        request.method == method
            && segments.count == pattern.count
            && zip(segments, pattern).allSatisfy { $1 == nil || $0 == $1 }
    }

    private func route(_ request: HTTPRequest, _ segments: [String]) async throws -> HTTPResponse {
        if matches(request, segments, "GET", ["state"]) {
            return .json(await backend.snapshot())
        }
        if matches(request, segments, "GET", ["history"]) {
            return .json(await backend.historyEntries())
        }
        if matches(request, segments, "PUT", ["config"]) {
            let configuration = try decode(ReviewBotConfiguration.self, from: request)
            let version = await backend.replaceConfiguration(configuration)
            return .json(["configurationVersion": version])
        }
        if matches(request, segments, "POST", ["run-now"]) {
            await backend.runNow()
            return .empty()
        }
        if matches(request, segments, "POST", ["toggle-paused"]) {
            await backend.togglePaused()
            return .empty()
        }
        if matches(request, segments, "POST", ["refresh-tools"]) {
            await backend.refreshToolAvailability()
            return .empty()
        }
        if matches(request, segments, "POST", ["history", "clear"]) {
            await backend.clearHistory()
            return .empty()
        }
        if matches(request, segments, "POST", ["open-data-folder"]) {
            await backend.openDataFolder()
            return .empty()
        }
        if matches(request, segments, "POST", ["quit"]) {
            await backend.quit()
            return .empty()
        }
        if matches(request, segments, "POST", ["repositories"]) {
            let body = try decode(RepositoryRequest.self, from: request)
            let folder = body.folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folder.isEmpty else { throw RouteError(status: 400, message: "folder is required") }
            do {
                try await backend.addRepository(folder: folder)
            } catch {
                // The folder is the page's input, so its failure is the page's to fix.
                throw RouteError(status: 400, message: error.localizedDescription)
            }
            return .empty()
        }
        if matches(request, segments, "DELETE", ["repositories", nil]) {
            guard let uuid = UUID(uuidString: segments[1]) else {
                throw RouteError(status: 400, message: "not a repository id")
            }
            await backend.removeRepository(id: uuid)
            return .empty()
        }
        if matches(request, segments, "PUT", ["keys", nil]) {
            let reviewer = try self.reviewer(named: segments[1])
            let body = try decode(KeyRequest.self, from: request)
            await backend.saveAPIKey(body.key, for: reviewer)
            return .empty()
        }
        if matches(request, segments, "DELETE", ["keys", nil]) {
            let reviewer = try self.reviewer(named: segments[1])
            await backend.removeAPIKey(for: reviewer)
            return .empty()
        }
        if matches(request, segments, "PUT", ["launch-at-login"]) {
            let body = try decode(EnabledRequest.self, from: request)
            await backend.setLaunchAtLogin(body.enabled)
            return .empty()
        }
        throw RouteError(status: 404, message: "no such route")
    }

    private struct RepositoryRequest: Decodable { var folder: String }
    private struct KeyRequest: Decodable { var key: String }
    private struct EnabledRequest: Decodable { var enabled: Bool }

    private func decode<T: Decodable>(_ type: T.Type, from request: HTTPRequest) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: request.body)
        } catch {
            throw RouteError(status: 400, message: "invalid request body: \(error.localizedDescription)")
        }
    }

    private func reviewer(named name: String) throws -> ReviewerName {
        guard let reviewer = ReviewerName(rawValue: name) else {
            throw RouteError(status: 404, message: "no reviewer named \(name)")
        }
        return reviewer
    }
}
