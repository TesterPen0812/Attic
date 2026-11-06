import Foundation
import Security

/// Claude credentials are per-app-identity Keychain items, never preferences.
struct AgentAPIKeyStore {
    enum Failure: Error { case missingIdentity, invalidCredential, keychain(OSStatus) }

    let service: String
    private let read: (String) throws -> String?
    private let write: (String, String) throws -> Void
    private let erase: (String) throws -> Void
    private static let account = "claude-api-key"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
         read: @escaping (String) throws -> String? = AgentAPIKeyStore.readKey,
         write: @escaping (String, String) throws -> Void = AgentAPIKeyStore.writeKey,
         erase: @escaping (String) throws -> Void = AgentAPIKeyStore.eraseKey) {
        service = bundleIdentifier.isEmpty ? "" : "\(bundleIdentifier).claude-api"
        self.read = read
        self.write = write
        self.erase = erase
    }

    func load() throws -> String? {
        guard !service.isEmpty else { throw Failure.missingIdentity }
        let result = try read(service)
        if let result, result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure.invalidCredential
        }
        return result
    }

    func save(_ key: String) throws {
        guard !service.isEmpty else { throw Failure.missingIdentity }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Failure.invalidCredential }
        try write(service, value)
    }

    func remove() throws {
        guard !service.isEmpty else { throw Failure.missingIdentity }
        try erase(service)
    }

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readKey(service: String) throws -> String? {
        var q = query(service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Failure.invalidCredential
        }
        return key
    }

    private static func writeKey(service: String, key: String) throws {
        var q = query(service: service)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw Failure.keychain(status) }
        let update: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(query(service: service) as CFDictionary, update as CFDictionary)
        guard updated == errSecSuccess else { throw Failure.keychain(updated) }
    }

    private static func eraseKey(service: String) throws {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
