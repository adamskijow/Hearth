// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerEnvEditorTests {
    @Test func foldsRowsTrimmingAndDroppingBlankKeys() {
        let env = RunnerEnvEditor.fold([
            ("OLLAMA_LOAD_TIMEOUT", "10m"),
            ("  ", "orphan value"),     // blank key dropped
            ("  OLLAMA_KEEP_ALIVE ", " 30m "),
        ])
        #expect(env == ["OLLAMA_LOAD_TIMEOUT": "10m", "OLLAMA_KEEP_ALIVE": "30m"])
    }

    @Test func laterDuplicateKeyWins() {
        #expect(RunnerEnvEditor.fold([("K", "1"), ("K", "2")]) == ["K": "2"])
    }

    @Test func emptyRowsFoldToEmpty() {
        #expect(RunnerEnvEditor.fold([]).isEmpty)
        #expect(RunnerEnvEditor.fold([("", ""), ("   ", "x")]).isEmpty)
    }
}
