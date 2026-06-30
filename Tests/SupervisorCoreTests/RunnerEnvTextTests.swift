// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerEnvTextTests {
    @Test func formatsSortedKeyValueLines() {
        #expect(RunnerEnvText.format(["B": "2", "A": "1"]) == "A=1\nB=2")
        #expect(RunnerEnvText.format([:]) == "")
    }

    @Test func parsesLeniently() {
        let env = RunnerEnvText.parse("""
        OLLAMA_LOAD_TIMEOUT=10m
          OLLAMA_KEEP_ALIVE = 30m

        # a comment line is ignored
        NOEQUALS
        =novalue
        """)
        #expect(env["OLLAMA_LOAD_TIMEOUT"] == "10m")
        #expect(env["OLLAMA_KEEP_ALIVE"] == "30m")   // whitespace around the = is trimmed
        #expect(env["NOEQUALS"] == nil)              // no '=' so dropped
        #expect(env[""] == nil)                      // empty key dropped
        #expect(env.count == 2)
    }

    @Test func laterDuplicateKeyWins() {
        #expect(RunnerEnvText.parse("K=1\nK=2")["K"] == "2")
    }

    @Test func onlyTheFirstEqualsSplits() {
        // A value may itself contain an '=' (rare, but should survive).
        #expect(RunnerEnvText.parse("K=a=b")["K"] == "a=b")
    }

    @Test func roundTrips() {
        let env = ["OLLAMA_LOAD_TIMEOUT": "10m", "OLLAMA_KEEP_ALIVE": "30m"]
        #expect(RunnerEnvText.parse(RunnerEnvText.format(env)) == env)
    }
}
