import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Errore Portachiavi \(status)"
        }
    }
}

public struct KeychainSecretStore: SecretStoring {
    private let service: String

    public init(service: String = "it.basileandrea.tabula") {
        self.service = service
    }

    public func password(for connectionID: UUID) throws -> String? {
        var query = baseQuery(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.unexpectedStatus(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setPassword(_ password: String?, for connectionID: UUID) throws {
        let deleteStatus = SecItemDelete(baseQuery(connectionID) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }
        guard let password, !password.isEmpty else { return }
        var item = baseQuery(connectionID)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Tabula — connessione"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func baseQuery(_ connectionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
        ]
    }
}
