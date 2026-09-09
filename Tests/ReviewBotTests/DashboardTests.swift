import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ReviewBot

/// The dashboard's transport and routes, driven without a socket or a tray: requests are
/// parsed from bytes and handed to `DashboardAPI` over a fake backend, so what the page can
/// and cannot do is pinned down on every platform.
final class DashboardTests: XCTestCase {
    // MARK: - Request parsing

    func testParserReadsRequestLineHeadersQueryAndBody() throws {
        let raw = "PUT /api/keys/Claude?t=abc&x=1%202 HTTP/1.1\r\nHost: 127.0.0.1:5\r\nContent-Length: 11\r\nAuthorization: Bearer tok\r\n\r\n{\"key\":\"k\"}"
        guard case let .complete(request) = HTTPRequestParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected a complete request")
        }

        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/keys/Claude")
        XCTAssertEqual(request.pathSegments, ["api", "keys", "Claude"])
        XCTAssertEqual(request.query, ["t": "abc", "x": "1 2"])
        XCTAssertEqual(request.headers["authorization"], "Bearer tok")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{\"key\":\"k\"}")
    }

    func testParserWaitsForTheWholeBody() {
        let raw = "POST /api/repositories HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"folder\":"
        guard case .incomplete = HTTPRequestParser.parse(Data(raw.utf8)) else {
            return XCTFail("a short body must be reported as incomplete, not truncated")
        }
    }

    func testParserRefusesAnOversizedBody() {
        let raw = "POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"
        guard case .invalid = HTTPRequestParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected the size cap to reject the request")
        }
    }

    func testResponseSerializationClosesTheConnectionAndDeniesFraming() {
        let bytes = HTTPResponse.json(["ok": true]).serialized()
        let text = String(decoding: bytes, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("X-Frame-Options: DENY\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }

    // MARK: - Routes

    @MainActor
    private final class FakeBackend: DashboardBackend {
        var configuration = ReviewBotConfiguration.default
        var version = 1
        var actions: [String] = []
        var keys: [ReviewerName: String] = [:]

        func snapshot() -> DashboardSnapshot {
            DashboardSnapshot(
                status: "Watching", isRunning: false, lastCheckDate: nil, toolAvailability: [:],
                githubAccounts: GitHubAccounts(accounts: ["alice"], active: "alice"),
                reviewersWithSavedKey: Array(keys.keys), launchAtLoginEnabled: false,
                pendingReviews: [], runningReviews: [], errorMessage: nil,
                configuration: configuration, configurationVersion: version, historyCount: 0,
                lastEventKind: nil, dataFolder: "C:\\data", version: "test",
                reviewers: ReviewerDescriptor.all
            )
        }
        func historyEntries() -> [HistoryEntry] { [] }
        func replaceConfiguration(_ configuration: ReviewBotConfiguration) -> Int {
            self.configuration = configuration
            version += 1
            return version
        }
        func runNow() { actions.append("runNow") }
        func togglePaused() { actions.append("togglePaused") }
        func addRepository(folder: String) throws {
            actions.append("add \(folder)")
            struct NotARepository: LocalizedError { var errorDescription: String? { "not a repository" } }
            if folder.contains("bad") { throw NotARepository() }
        }
        func removeRepository(id: UUID) { actions.append("remove \(id)") }
        func saveAPIKey(_ key: String, for reviewer: ReviewerName) { keys[reviewer] = key }
        func removeAPIKey(for reviewer: ReviewerName) { keys[reviewer] = nil }
        func setLaunchAtLogin(_ enabled: Bool) { actions.append("launch \(enabled)") }
        func clearHistory() { actions.append("clearHistory") }
        func refreshToolAvailability() { actions.append("refreshTools") }
        func openDataFolder() { actions.append("openDataFolder") }
        func quit() { actions.append("quit") }
    }

    private func request(
        _ method: String,
        _ path: String,
        body: String = "",
        token: String? = "secret",
        host: String? = "127.0.0.1:8080"
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        if let host { headers["host"] = host }
        let target = path.split(separator: "?", maxSplits: 1)
        return HTTPRequest(
            method: method,
            path: String(target[0]),
            query: [:],
            headers: headers,
            body: Data(body.utf8)
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: response.body)
    }

    @MainActor
    func testThePageIsServedWithoutATokenButTheAPIIsNot() async {
        let api = DashboardAPI(backend: FakeBackend(), token: "secret", page: "<p>page</p>")

        let page = await api.handle(request("GET", "/", token: nil))
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(String(decoding: page.body, as: UTF8.self), "<p>page</p>")

        let missing = await api.handle(request("GET", "/api/state", token: nil))
        XCTAssertEqual(missing.status, 401)
        let wrong = await api.handle(request("GET", "/api/state", token: "secre"))
        XCTAssertEqual(wrong.status, 401)
        // A request that reached this server through some other host name is not from the page.
        let rebound = await api.handle(request("GET", "/api/state", host: "evil.example:8080"))
        XCTAssertEqual(rebound.status, 401)
    }

    @MainActor
    func testStateCarriesTheConfigurationAndTheReviewerSurface() async throws {
        let backend = FakeBackend()
        let api = DashboardAPI(backend: backend, token: "secret")

        let response = await api.handle(request("GET", "/api/state"))
        XCTAssertEqual(response.status, 200)
        let snapshot = try decode(DashboardSnapshot.self, from: response)

        XCTAssertEqual(snapshot.configuration, backend.configuration)
        XCTAssertEqual(snapshot.reviewers.map(\.name), ReviewerName.allCases)
        // The page draws its cards from these flags, so they must match the reviewer's own.
        let deepseek = try XCTUnwrap(snapshot.reviewers.first { $0.name == .deepseek })
        XCTAssertFalse(deepseek.supportsSessionAuth)
        XCTAssertTrue(deepseek.needsConfiguredPricing)
        XCTAssertEqual(deepseek.defaultPricing, ReviewerName.deepseek.defaultPricing)
        let opencode = try XCTUnwrap(snapshot.reviewers.first { $0.name == .opencode })
        XCTAssertFalse(opencode.supportsAPIKeyAuth)
    }

    @MainActor
    func testReplacingTheConfigurationRoundTripsAndReportsTheNewVersion() async throws {
        let backend = FakeBackend()
        let api = DashboardAPI(backend: backend, token: "secret")
        var edited = backend.configuration
        edited.customPrompt = "Be strict about error handling."
        edited.claude.authMode = .apiKey
        edited.failureBudget = .unlimited
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = String(decoding: try encoder.encode(edited), as: UTF8.self)

        let response = await api.handle(request("PUT", "/api/config", body: body))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try decode([String: Int].self, from: response), ["configurationVersion": 2])
        XCTAssertEqual(backend.configuration, edited)
    }

    @MainActor
    func testAMalformedConfigurationIsRejectedWithoutTouchingTheStoredOne() async {
        let backend = FakeBackend()
        let api = DashboardAPI(backend: backend, token: "secret")
        let before = backend.configuration

        let response = await api.handle(request("PUT", "/api/config", body: "{\"claude\":"))

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(backend.configuration, before)
        XCTAssertEqual(backend.version, 1)
    }

    @MainActor
    func testActionsReachTheBackend() async throws {
        let backend = FakeBackend()
        let api = DashboardAPI(backend: backend, token: "secret")
        let id = UUID()

        for (method, path, body) in [
            ("POST", "/api/run-now", ""),
            ("POST", "/api/toggle-paused", ""),
            ("POST", "/api/refresh-tools", ""),
            ("POST", "/api/history/clear", ""),
            ("POST", "/api/open-data-folder", ""),
            ("POST", "/api/repositories", "{\"folder\":\"C:\\\\src\\\\repo\"}"),
            ("DELETE", "/api/repositories/\(id.uuidString)", ""),
            ("PUT", "/api/launch-at-login", "{\"enabled\":true}"),
            ("POST", "/api/quit", ""),
        ] {
            let response = await api.handle(request(method, path, body: body))
            XCTAssertEqual(response.status, 204, "\(method) \(path)")
        }

        XCTAssertEqual(backend.actions, [
            "runNow", "togglePaused", "refreshTools", "clearHistory", "openDataFolder",
            "add C:\\src\\repo", "remove \(id)", "launch true", "quit",
        ])
    }

    @MainActor
    func testARepositoryThatCannotBeInspectedIsAClientError() async throws {
        let api = DashboardAPI(backend: FakeBackend(), token: "secret")

        let response = await api.handle(request("POST", "/api/repositories", body: "{\"folder\":\"C:\\\\bad\"}"))

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try decode([String: String].self, from: response), ["error": "not a repository"])
    }

    @MainActor
    func testKeysAreSavedAndRemovedPerReviewer() async throws {
        let backend = FakeBackend()
        let api = DashboardAPI(backend: backend, token: "secret")

        let saved = await api.handle(request("PUT", "/api/keys/DeepSeek", body: "{\"key\":\"sk-1\"}"))
        XCTAssertEqual(saved.status, 204)
        XCTAssertEqual(backend.keys, [.deepseek: "sk-1"])

        let unknown = await api.handle(request("PUT", "/api/keys/Gemini", body: "{\"key\":\"sk-1\"}"))
        XCTAssertEqual(unknown.status, 404)

        let removed = await api.handle(request("DELETE", "/api/keys/DeepSeek"))
        XCTAssertEqual(removed.status, 204)
        XCTAssertEqual(backend.keys, [:])
    }

    @MainActor
    func testUnknownRoutesAndWrongMethodsAreRefused() async {
        let api = DashboardAPI(backend: FakeBackend(), token: "secret")
        let missing = await api.handle(request("GET", "/api/nothing"))
        XCTAssertEqual(missing.status, 404)
        let wrongMethod = await api.handle(request("GET", "/api/run-now"))
        XCTAssertEqual(wrongMethod.status, 404)
        let notAPI = await api.handle(request("GET", "/other", token: nil))
        XCTAssertEqual(notAPI.status, 404)
    }

    // MARK: - Over a socket

    /// One real round trip through `LocalHTTPServer`, so the socket code is exercised on every
    /// platform CI runs on — it is the one place the shared core calls an OS API directly.
    @MainActor
    func testTheServerAnswersOverLoopback() async throws {
        let api = DashboardAPI(backend: FakeBackend(), token: "secret", page: "<p>hello</p>")
        let server = LocalHTTPServer { await api.handle($0) }
        let port = try server.start()
        defer { server.stop() }
        XCTAssertNotEqual(port, 0)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/state")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let snapshot = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        XCTAssertEqual(snapshot.status, "Watching")

        let (page, pageResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: page, as: UTF8.self), "<p>hello</p>")
    }
}
