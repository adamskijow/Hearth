// SPDX-License-Identifier: MIT

import Foundation

/// Folding the ordered key/value rows of the runner-environment editor into the
/// final environment map: keys are trimmed and blank keys dropped, values are
/// trimmed, and a later duplicate key wins. Pure so the rules are testable without
/// the UI.
public enum RunnerEnvEditor {
    public static func fold(_ rows: [(String, String)]) -> [String: String] {
        var env: [String: String] = [:]
        for (rawKey, rawValue) in rows {
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = rawValue.trimmingCharacters(in: .whitespaces)
        }
        return env
    }
}
