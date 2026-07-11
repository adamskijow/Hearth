// SPDX-License-Identifier: MIT

import Foundation
import Security

protocol MonitorSecretStoring: Sendable {
    func token(for targetID: UUID) throws -> String?
    func setToken(_ token: String, for targetID: UUID) throws
    func deleteToken(for targetID: UUID) throws
}

struct MonitorKeychainSecretStore: MonitorSecretStoring, Sendable {
    private static let service = "com.hearth.HearthMonitor.full-hearth-status"

    struct KeychainError: LocalizedError, Sendable, Equatable {
        var operation: String
        var status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(detail)"
        }
    }

    func token(for targetID: UUID) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(targetID).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(operation: "read", status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(operation: "decode", status: errSecDecode)
        }
        return token
    }

    func setToken(_ token: String, for targetID: UUID) throws {
        guard let data = token.data(using: .utf8), !data.isEmpty, data.count <= 4096 else {
            throw KeychainError(operation: "write", status: errSecParam)
        }
        let query = baseQuery(targetID)
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw KeychainError(operation: "update", status: updated)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Hearth Monitor status token"
        item[kSecAttrDescription as String] = "Read-only full Hearth status credential"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(operation: "add", status: added) }
    }

    func deleteToken(for targetID: UUID) throws {
        let status = SecItemDelete(baseQuery(targetID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", status: status)
        }
    }

    private func baseQuery(_ targetID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: targetID.uuidString,
        ]
    }
}
