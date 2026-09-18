import Security
import XCTest
@testable import Attic

final class AgentAccessTokenStoreTests: XCTestCase {
    func testCreatesPersistentCredentialAndReusesItOnReopen() throws {
        var saved: [String: String] = [:]
        let store = AgentAccessTokenStore(
            bundleIdentifier: "com.taha.Attic.test",
            read: { saved[$0] },
            insert: { service, token in saved[service] = token; return true }
        )
        let first = try store.loadOrCreate()
        XCTAssertTrue(AgentAccessTokenStore.isValid(first))
        XCTAssertEqual(try store.loadOrCreate(), first)
        XCTAssertEqual(saved.count, 1)
    }

    func testPreviewAndDailyCredentialsAreIsolated() throws {
        var saved: [String: String] = [:]
        func store(_ identity: String) -> AgentAccessTokenStore {
            AgentAccessTokenStore(
                bundleIdentifier: identity,
                read: { saved[$0] },
                insert: { service, token in saved[service] = token; return true }
            )
        }
        let daily = try store("com.taha.Attic").loadOrCreate()
        let preview = try store("com.taha.Attic.preview").loadOrCreate()
        XCTAssertNotEqual(daily, preview)
        XCTAssertEqual(saved.count, 2)
    }

    func testUnavailableKeychainFailsWithoutGeneratingOrReturningFallback() {
        let store = AgentAccessTokenStore(
            bundleIdentifier: "test",
            read: { _ in throw AgentAccessTokenStore.Failure.keychain(errSecInteractionNotAllowed) },
            insert: { _, _ in XCTFail("Must not write after read failure"); return true },
            generate: { XCTFail("Must not generate after read failure"); return "" }
        )
        XCTAssertThrowsError(try store.loadOrCreate())
    }

    func testPersistenceFailureDoesNotReturnEphemeralToken() {
        let store = AgentAccessTokenStore(
            bundleIdentifier: "test",
            read: { _ in nil },
            insert: { _, _ in throw AgentAccessTokenStore.Failure.keychain(errSecAuthFailed) }
        )
        XCTAssertThrowsError(try store.loadOrCreate())
    }

    func testInsertRaceUsesWinningPersistedCredential() throws {
        let winning = try AgentAccessTokenStore.generateToken()
        var readCount = 0
        let store = AgentAccessTokenStore(
            bundleIdentifier: "test",
            read: { _ in readCount += 1; return readCount == 1 ? nil : winning },
            insert: { _, _ in false }
        )
        XCTAssertEqual(try store.loadOrCreate(), winning)
    }

    func testRejectsMissingIdentityAndStoredPlaceholder() {
        let missing = AgentAccessTokenStore(bundleIdentifier: "", read: { _ in
            XCTFail("Missing identity must not query shared credentials")
            return nil
        })
        XCTAssertThrowsError(try missing.loadOrCreate())
        let placeholder = AgentAccessTokenStore(bundleIdentifier: "test", read: { _ in
            "attic-local-only-agent-disabled"
        })
        XCTAssertThrowsError(try placeholder.loadOrCreate())
        XCTAssertFalse(AgentAccessTokenStore.isValid(""))
        XCTAssertFalse(AgentAccessTokenStore.isValid("attic-test-agent-token"))
        XCTAssertFalse(AgentAccessTokenStore.isValid(String(repeating: "é", count: 43)))
    }
}
