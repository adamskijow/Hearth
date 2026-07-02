// SPDX-License-Identifier: MIT

import Foundation

/// Where a Homebrew-cask install of Hearth leaves its footprint. The cask moves
/// the app to /Applications and links the CLI, so the running executable's path
/// says nothing about how it was installed; the Caskroom directory is the
/// durable signal. Pure so the derivation is testable; the caller checks disk.
public enum SelfUpdate {
    /// The Caskroom directory for the hearth cask, derived from the brew binary
    /// path (/opt/homebrew/bin/brew on Apple Silicon, /usr/local/bin/brew on
    /// Intel), so both layouts resolve without hardcoding either prefix.
    public static func caskroomPath(forBrew brew: String) -> String {
        let prefix = URL(fileURLWithPath: brew)
            .deletingLastPathComponent()   // bin
            .deletingLastPathComponent()   // the brew prefix
            .path
        return prefix + "/Caskroom/hearth"
    }
}
