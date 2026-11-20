import Foundation
import Security
import PaperDeskCore

private final class FakeCredentialBackend: CredentialBackend {
    var values: [String: String] = [:]
    var readStatus: OSStatus?
    var writeStatus: OSStatus?
    var reads: [String] = []
    var writes: [String] = []
    func read(account: String) throws -> String? {
        reads.append(account)
        if let readStatus { throw CredentialAccessError(status: readStatus, operation: .read) }
        return values[account]
    }
    func write(_ value: String, account: String) throws {
        writes.append(account)
        if let writeStatus { throw CredentialAccessError(status: writeStatus, operation: .write) }
        values[account] = value
    }
}

extension PaperDeskCoreTests {
    @MainActor func testCredentialRecoveryAndSessionIsolation() throws {
        let backend = FakeCredentialBackend()
        backend.readStatus = errSecAuthFailed
        let session = CredentialSession(backend: backend)
        try XCTAssertThrowsError(session.read(account: "endpoint:a"))
        // Explicit session-only input remains usable despite denied Keychain access, and never writes.
        try session.write("synthetic-session-key", account: "endpoint:a", remember: false)
        try XCTAssertEqual(session.read(account: "endpoint:a"), "synthetic-session-key")
        try XCTAssertEqual(backend.reads, ["endpoint:a"])
        try XCTAssertTrue(backend.writes.isEmpty)
        try XCTAssertThrowsError(session.read(account: "endpoint:b"))
        try XCTAssertTrue(session.isSessionOnly(account: "endpoint:a"))
        // An explicit empty session key also bypasses Keychain for local no-auth models.
        try session.write("", account: "endpoint:local", remember: false)
        try XCTAssertEqual(session.read(account: "endpoint:local"), "")
        try XCTAssertThrowsError(CredentialSession(backend: backend).read(account: "endpoint:a"))
    }

    @MainActor func testCredentialSaveDoesNotDependOnLegacyRead() throws {
        let backend = FakeCredentialBackend()
        backend.readStatus = errSecAuthFailed
        let session = CredentialSession(backend: backend)
        try session.write("new-synthetic-key", account: "endpoint:a", remember: true)
        try XCTAssertTrue(backend.reads.isEmpty)
        try XCTAssertEqual(session.read(account: "endpoint:a", legacyAccount: "api-key"), "new-synthetic-key")
        try XCTAssertFalse(session.isSessionOnly(account: "endpoint:a"))
        // A failed save must retain the working session credential, without claiming persistence.
        try session.write("temporary", account: "endpoint:b", remember: false)
        backend.writeStatus = errSecAuthFailed
        try XCTAssertThrowsError(session.write("rejected", account: "endpoint:b", remember: true))
        try XCTAssertEqual(session.read(account: "endpoint:b"), "temporary")
        try XCTAssertTrue(session.isSessionOnly(account: "endpoint:b"))
        backend.writeStatus = nil
        try session.write("saved", account: "endpoint:b", remember: true)
        try XCTAssertFalse(session.isSessionOnly(account: "endpoint:b"))
    }

    @MainActor func testCredentialLegacyAndRetry() throws {
        let backend = FakeCredentialBackend()
        backend.values["api-key"] = "legacy"
        let session = CredentialSession(backend: backend)
        try XCTAssertEqual(session.read(account: "endpoint:a", legacyAccount: "api-key"), "legacy")
        try XCTAssertEqual(backend.reads, ["endpoint:a", "api-key"])
        try XCTAssertTrue(session.read(account: "endpoint:b") == nil)
        // Failed reads are not cached; unlock/authorization can recover without restarting.
        backend.readStatus = errSecInteractionNotAllowed
        try XCTAssertThrowsError(session.read(account: "endpoint:c"))
        backend.readStatus = nil; backend.values["endpoint:c"] = "recovered"
        try XCTAssertEqual(session.read(account: "endpoint:c"), "recovered")
        let message = CredentialAccessError(status: errSecAuthFailed, operation: .read).localizedDescription
        try XCTAssertTrue(message.contains("-25293") && message.contains("仅本次运行"))
    }
}
