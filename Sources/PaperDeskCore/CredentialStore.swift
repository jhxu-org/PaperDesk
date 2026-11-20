import Foundation
import Security

public struct CredentialAccessError: LocalizedError {
    public enum Operation { case read, write }
    public let status: OSStatus
    public let operation: Operation
    public init(status: OSStatus, operation: Operation) { self.status = status; self.operation = operation }
    public var errorDescription: String? {
        switch status {
        case errSecAuthFailed:
            return "macOS 未允许此版本访问钥匙串凭据（\(status)）。可重试并在系统提示中授权，或重新填写凭据后选择仅本次运行使用。"
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return "钥匙串当前不可访问（\(status)）。请解锁 Mac 后重试；也可重新填写凭据并选择仅本次运行使用。"
        case errSecUserCanceled:
            return "钥匙串授权已取消。可以重试，或重新填写凭据并选择仅本次运行使用。"
        default:
            return "无法\(operation == .read ? "读取" : "保存")钥匙串凭据（\(status)）。可重试，或重新填写凭据后选择仅本次运行使用。"
        }
    }
}

public protocol CredentialBackend {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
}

public struct KeychainBackend: CredentialBackend {
    private let service: String
    public init(service: String) { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read(account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialAccessError(status: status, operation: .read) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialAccessError(status: errSecDecode, operation: .read)
        }
        return value
    }
    public func write(_ value: String, account: String) throws {
        let query = query(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialAccessError(status: status, operation: .write)
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialAccessError(status: status, operation: .write) }
    }
}

/// Successful reads and explicit session credentials are isolated by account and live only in memory.
/// Failed writes never turn into silent plaintext storage or replace the last working credential.
@MainActor public final class CredentialSession {
    private let backend: any CredentialBackend
    private var values: [String: String] = [:]
    private var temporaryAccounts = Set<String>()
    public init(backend: any CredentialBackend) { self.backend = backend }
    public func isSessionOnly(account: String) -> Bool { temporaryAccounts.contains(account) }
    public func read(account: String, legacyAccount: String? = nil) throws -> String? {
        if let value = values[account] { return value }
        let value: String?
        if let current = try backend.read(account: account) { value = current }
        else if let legacyAccount { value = try backend.read(account: legacyAccount) }
        else { value = nil }
        if let value { values[account] = value }
        return value
    }
    public func write(_ value: String, account: String, remember: Bool) throws {
        if remember {
            // Do not read a legacy credential first: re-entering a key must be able to recover a failed read.
            try backend.write(value, account: account)
            temporaryAccounts.remove(account)
        } else { temporaryAccounts.insert(account) }
        values[account] = value
    }
}
