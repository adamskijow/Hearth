// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerLocationTests {
    @Test func ollamaProbesHomebrewIntelAndTheAppBundle() {
        let c = RunnerLocation.candidates(for: "ollama", home: "/Users/x", path: nil)
        #expect(c.first == "/opt/homebrew/bin/ollama")
        #expect(c.contains("/usr/local/bin/ollama"))
        #expect(c.contains("/Applications/Ollama.app/Contents/Resources/ollama"))
    }

    @Test func lmStudioPrefersTheUserBinDirectory() {
        let c = RunnerLocation.candidates(for: "lmstudio", home: "/Users/x", path: nil)
        #expect(c.first == "/Users/x/.lmstudio/bin/lms")
        #expect(c.contains("/opt/homebrew/bin/lms"))
    }

    @Test func mlxProbesTheServerEntryPoint() {
        let c = RunnerLocation.candidates(for: "mlx", home: "/Users/x", path: nil)
        #expect(c.first == "/opt/homebrew/bin/mlx_lm.server")
        #expect(c.allSatisfy { $0.hasSuffix("mlx_lm.server") })
    }

    @Test func runnerKindMatchingIsCaseAndSeparatorInsensitive() {
        let a = RunnerLocation.candidates(for: "LM-Studio", home: "/h", path: nil)
        let b = RunnerLocation.candidates(for: "lm_studio", home: "/h", path: nil)
        #expect(a == b)
        #expect(a.first == "/h/.lmstudio/bin/lms")
    }

    @Test func pathEntriesAreAppendedAsCandidates() {
        let c = RunnerLocation.candidates(for: "ollama", home: "/h", path: "/a/bin:/b/bin")
        #expect(c.contains("/a/bin/ollama"))
        #expect(c.contains("/b/bin/ollama"))
        // Well known locations still come first.
        #expect(c.first == "/opt/homebrew/bin/ollama")
    }

    @Test func aNilPathAddsNoPathCandidates() {
        let c = RunnerLocation.candidates(for: "ollama", home: "/h", path: nil)
        #expect(!c.contains { $0.hasPrefix("/a") })
        #expect(c.count == 3)
    }
}
