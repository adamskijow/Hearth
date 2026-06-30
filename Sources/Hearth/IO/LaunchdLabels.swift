// SPDX-License-Identifier: MIT

import Foundation

/// Reads the labels of the user's loaded launchd jobs, so Hearth can spot another
/// manager (such as `brew services`) keeping the same runner alive. Read only; it
/// runs `launchctl list` and parses the label column, nothing more.
enum LaunchdLabels {
    static func loaded() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Output is tab-separated "PID\tStatus\tLabel" with a header row.
        var labels: Set<String> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            if let label = line.split(separator: "\t").last, label != "Label" {
                labels.insert(String(label))
            }
        }
        return labels
    }
}
