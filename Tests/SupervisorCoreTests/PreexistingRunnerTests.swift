// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct PreexistingRunnerTests {
    @Test func warnsOnlyInManagedModeWithAForeignRunner() {
        #expect(PreexistingRunner.warning(runner: "ollama", mode: "managed", foreignRunnerServing: true) != nil)
        // Attached mode exists to watch an already-running runner: no warning.
        #expect(PreexistingRunner.warning(runner: "ollama", mode: "attached", foreignRunnerServing: true) == nil)
        // Nothing foreign on the port: no warning.
        #expect(PreexistingRunner.warning(runner: "ollama", mode: "managed", foreignRunnerServing: false) == nil)
    }

    @Test func ollamaMessageNamesTheAppAndTheFix() {
        let w = PreexistingRunner.warning(runner: "ollama", mode: "managed", foreignRunnerServing: true)
        #expect(w?.contains("Ollama app") == true)
        #expect(w?.contains("attached") == true)
    }

    @Test func nonOllamaMessageStaysGeneric() {
        let w = PreexistingRunner.warning(runner: "mlx", mode: "managed", foreignRunnerServing: true)
        #expect(w != nil)
        #expect(w?.contains("Ollama app") == false)
    }
}
