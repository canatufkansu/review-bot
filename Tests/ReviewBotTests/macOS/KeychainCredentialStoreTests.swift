import XCTest
@testable import ReviewBot

/// These tests deliberately never write to the Keychain — they use a service name no install
/// owns, so every Keychain lookup misses and the environment override is what is under test.
/// A miss returns `errSecItemNotFound` without user interaction, so the suite cannot prompt.
final class KeychainCredentialStoreTests: XCTestCase {
    private let unusedService = "Review Bot tests — no such Keychain item"

    func testEnvironmentOverrideSuppliesKeyWithoutKeychain() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["DEEPSEEK_API_KEY": "sk-from-environment"]
        )
        XCTAssertEqual(store.apiKey(for: .deepseek), "sk-from-environment")
    }

    func testEnvironmentOverrideIsTrimmed() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["DEEPSEEK_API_KEY": "  sk-padded\n"]
        )
        XCTAssertEqual(store.apiKey(for: .deepseek), "sk-padded")
    }

    func testBlankEnvironmentValueIsIgnored() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["DEEPSEEK_API_KEY": "   "]
        )
        XCTAssertNil(store.apiKey(for: .deepseek))
    }

    func testOverrideAppliesOnlyToItsOwnReviewer() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["ANTHROPIC_API_KEY": "sk-anthropic"]
        )
        XCTAssertEqual(store.apiKey(for: .claude), "sk-anthropic")
        XCTAssertNil(store.apiKey(for: .deepseek))
        XCTAssertNil(store.apiKey(for: .codex))
    }

    func testEmptyEnvironmentFallsThroughToKeychain() {
        let store = KeychainCredentialStore(service: unusedService, environment: [:])
        // Nothing is stored under this service, so the Keychain path returns nil rather than
        // throwing or prompting.
        XCTAssertNil(store.apiKey(for: .deepseek))
    }
}
