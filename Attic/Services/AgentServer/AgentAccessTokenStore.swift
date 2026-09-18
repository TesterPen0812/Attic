import Foundation
import Security

struct AgentAccessTokenStore {
    enum Failure: Error {
        case missingIdentity, invalidCredential, randomGeneration, keychain(OSStatus)
    }

    let service: String
    private let read: (String) throws -> String?
    private let insert: (String, String) throws -> Bool
    private let generate: () throws -> String
    private static let account = "mcp-bearer-token"

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        read: @escaping (String) throws -> String? = AgentAccessTokenStore.readToken,
        insert: @escaping (String, String) throws -> Bool = AgentAccessTokenStore.insertToken,
        generate: @escaping () throws -> String = AgentAccessTokenStore.generateToken
    ) {
        service = bundleIdentifier.isEmpty ? "" : "\(bundleIdentifier).agent-access"
        self.read = read
        self.insert = insert
        self.generate = generate
    }

    func loadOrCreate() throws -> String {
        guard !service.isEmpty else { throw Failure.missingIdentity }
        if let existing = try read(service) {
            guard Self.isValid(existing) else { throw Failure.invalidCredential }
            return existing
        }
        let generated = try generate()
        guard Self.isValid(generated) else { throw Failure.invalidCredential }
        if try insert(service, generated) { return generated }
        // Another instance won the insert race. Use the persisted credential,
        // never an ephemeral fallback that silently breaks reconnects.
        guard let existing = try read(service), Self.isValid(existing) else {
            throw Failure.invalidCredential
        }
        return existing
    }

    static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.randomGeneration
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isValid(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func insertToken(service: String, token: String) throws -> Bool {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem { return false }
        throw Failure.keychain(status)
    }

    private static func readToken(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw Failure.invalidCredential
        }
        return token
    }
}
