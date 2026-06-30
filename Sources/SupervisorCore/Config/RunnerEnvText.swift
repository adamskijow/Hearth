// SPDX-License-Identifier: MIT

import Foundation

/// Converting a runner environment map to and from the editable `KEY=VALUE`
/// per-line text the Preferences window shows. Pure so the parsing rules are
/// testable without the UI. Parsing is lenient: blank lines, comment lines (`#`),
/// and lines with no `=` or an empty key are dropped; whitespace around the key
/// and value is trimmed; only the first `=` splits, so a value may contain one;
/// and a later duplicate key wins.
public enum RunnerEnvText {
    public static func format(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    public static func parse(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = value
        }
        return env
    }
}
