// SPDX-License-Identifier: MIT

import Foundation

/// Packaging diagnostic for the signed executable. It never prints or retains a
/// credential: a random value is written under a random account, read back, and
/// deleted before exit. App Store validation can run the same flag after signing.
enum MonitorKeychainSelfTest {
    static func run() -> Int32 {
        let store = MonitorKeychainSecretStore()
        let id = UUID()
        let token = "self-test-\(UUID().uuidString)"
        defer {
            try? store.deleteToken(for: id)
            try? store.deleteRunnerToken(for: id)
        }
        do {
            try store.setToken(token, for: id)
            guard try store.token(for: id) == token else {
                FileHandle.standardError.write(Data("Keychain self-test readback did not match.\n".utf8))
                return 1
            }
            try store.deleteToken(for: id)
            guard try store.token(for: id) == nil else {
                FileHandle.standardError.write(Data("Keychain self-test deletion did not complete.\n".utf8))
                return 1
            }
            try store.setRunnerToken(token, for: id)
            guard try store.runnerToken(for: id) == token else {
                FileHandle.standardError.write(Data("Keychain runner credential readback did not match.\n".utf8))
                return 1
            }
            try store.deleteRunnerToken(for: id)
            guard try store.runnerToken(for: id) == nil else {
                FileHandle.standardError.write(Data("Keychain runner credential deletion did not complete.\n".utf8))
                return 1
            }
            print("Hearth Monitor Keychain self-test passed.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Hearth Monitor Keychain self-test failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
