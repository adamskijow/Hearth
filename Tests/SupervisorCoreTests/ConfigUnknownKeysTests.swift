// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// Unknown-key (typo) detection: the lenient decoder silently ignores keys it
/// does not know, which is right for forward compatibility but must warn, or a
/// misspelled probeModel silently disables the deep probe.
struct ConfigUnknownKeysTests {
    private func warnings(_ json: String) -> [String] {
        ConfigDiagnostics.unknownKeys(inRawConfig: Data(json.utf8)).map(\.message)
    }

    @Test func aTypoWarnsWithASuggestion() {
        let messages = warnings(#"{"probemodel": "qwen2.5:0.5b"}"#)
        #expect(messages.count == 1)
        #expect(messages[0].contains("\"probemodel\""))
        #expect(messages[0].contains("did you mean \"probeModel\""))
    }

    @Test func knownKeysAreSilent() {
        #expect(warnings(#"{"probeModel": "x", "port": 11434, "controlTokens": {"a": "b"}}"#).isEmpty)
        #expect(warnings("{}").isEmpty)
    }

    @Test func aFarOffKeyWarnsWithoutASuggestion() {
        let messages = warnings(#"{"bananaboat": true}"#)
        #expect(messages.count == 1)
        #expect(messages[0].contains("\"bananaboat\""))
        #expect(!messages[0].contains("did you mean"))
        #expect(messages[0].contains("ignored"))
    }

    @Test func caseSlipsAreCaught() {
        // All-lowercase is a common hand-edit slip; distance 0 case-insensitively.
        let messages = warnings(#"{"controltoken": "secret"}"#)
        #expect(messages.count == 1)
        #expect(messages[0].contains("did you mean \"controlToken\""))
    }

    @Test func severityIsAlwaysWarningNeverError() {
        // A config from a newer Hearth must still load; unknown keys cannot fail it.
        let diagnostics = ConfigDiagnostics.unknownKeys(inRawConfig: Data(#"{"futureKey": 1}"#.utf8))
        #expect(diagnostics.allSatisfy { $0.severity == .warning })
    }

    @Test func malformedAndNonObjectJSONProduceNothing() {
        #expect(warnings("not json").isEmpty)
        #expect(warnings("[1,2,3]").isEmpty)
        #expect(warnings("").isEmpty)
    }

    @Test func multipleUnknownsAreSortedAndAllReported() {
        let messages = warnings(#"{"zzz": 1, "aaa": 2}"#)
        #expect(messages.count == 2)
        #expect(messages[0].contains("\"aaa\""))
        #expect(messages[1].contains("\"zzz\""))
    }

    @Test func resolveAttachesKeyDiagnosticsOnACleanParse() {
        let resolution = ConfigLoading.resolve(
            fileContents: Data(#"{"probemodel": "x"}"#.utf8), configPath: "/tmp/c.json", detectedBinary: nil)
        #expect(!resolution.isProblem)
        #expect(resolution.keyDiagnostics.count == 1)
        #expect(resolution.keyDiagnostics[0].message.contains("probeModel"))
    }

    @Test func resolveOnAParseFailureCarriesNoKeyDiagnostics() {
        let resolution = ConfigLoading.resolve(
            fileContents: Data("{broken".utf8), configPath: "/tmp/c.json", detectedBinary: nil)
        #expect(resolution.isProblem)
        #expect(resolution.keyDiagnostics.isEmpty)
    }

    // MARK: knownKeys derivation guards

    @Test func knownKeysCoversTheWholeSchema() {
        let keys = HearthConfig.knownKeys
        // Spot-check across every config section, including all the optionals.
        for expected in ["runner", "mode", "port", "probeModel", "maintenanceWindow",
                         "ntfyTopic", "webhookURL", "heartbeatURL", "controlToken",
                         "controlTokens", "runnerUser", "metricsProxyEnabled",
                         "rebootViaHelper", "busyTimeoutSeconds", "runnerMemoryLimitMB"] {
            #expect(keys.contains(expected), "knownKeys is missing \(expected)")
        }
    }

    @Test func fullyPopulatedHasNoNilFieldLeftBehind() {
        // The drift guard: a new optional property someone forgets to set in
        // fullyPopulated would silently vanish from knownKeys and then warn on
        // every config that legitimately uses it. Mirror catches that here.
        for child in Mirror(reflecting: HearthConfig.fullyPopulated).children {
            let mirror = Mirror(reflecting: child.value)
            if mirror.displayStyle == .optional {
                #expect(mirror.children.first != nil,
                        "fullyPopulated leaves \(child.label ?? "?") nil; set it so knownKeys stays complete")
            }
        }
    }

    @Test func editDistanceIsPlainLevenshtein() {
        #expect(ConfigDiagnostics.editDistance("", "abc") == 3)
        #expect(ConfigDiagnostics.editDistance("abc", "abc") == 0)
        #expect(ConfigDiagnostics.editDistance("probemodel", "probemodel") == 0)
        #expect(ConfigDiagnostics.editDistance("kitten", "sitting") == 3)
    }
}

/// Where `hearth update` looks for the cask footprint, on both brew layouts.
struct SelfUpdateTests {
    @Test func caskroomFollowsTheBrewPrefix() {
        #expect(SelfUpdate.caskroomPath(forBrew: "/opt/homebrew/bin/brew") == "/opt/homebrew/Caskroom/hearth")
        #expect(SelfUpdate.caskroomPath(forBrew: "/usr/local/bin/brew") == "/usr/local/Caskroom/hearth")
    }
}
