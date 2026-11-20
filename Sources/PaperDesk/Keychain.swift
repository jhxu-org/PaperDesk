import Foundation
import PaperDeskCore

@MainActor enum Keychain {
    static let service = Bundle.main.bundleIdentifier == "com.paperdesk.mac.uitests" ? "com.paperdesk.mac.uitests.ai" : "com.paperdesk.mac.ai"
    private static let session = CredentialSession(backend: KeychainBackend(service: service))
    static func read(account: String = "api-key", legacyAccount: String? = nil) throws -> String? {
        try session.read(account: account, legacyAccount: legacyAccount)
    }
    static func write(_ value: String, account: String = "api-key", remember: Bool = true) throws {
        try session.write(value, account: account, remember: remember)
    }
    static func isSessionOnly(account: String) -> Bool { session.isSessionOnly(account: account) }
}
