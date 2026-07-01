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
        #expect(w?.contains("hearth mode attached") == true)
    }

    @Test func nonOllamaMessageStaysGeneric() {
        let w = PreexistingRunner.warning(runner: "mlx", mode: "managed", foreignRunnerServing: true)
        #expect(w != nil)
        #expect(w?.contains("Ollama app") == false)
    }

    @Test func unknownListenerMessageDoesNotPretendItIsARunner() {
        let w = PreexistingRunner.unknownListenerWarning(runner: "ollama", host: "127.0.0.1", port: 11434)
        #expect(w.contains("did not answer as ollama"))
        #expect(w.contains("stop that process"))
    }

    @Test func attachedMissingMessagePointsToBothFixes() {
        let empty = PreexistingRunner.attachedMissingWarning(runner: "ollama", host: "127.0.0.1", port: 11434, listenerPresent: false)
        #expect(empty.contains("nothing is serving"))
        #expect(empty.contains("hearth mode managed"))

        let wrong = PreexistingRunner.attachedMissingWarning(runner: "ollama", host: "127.0.0.1", port: 11434, listenerPresent: true)
        #expect(wrong.contains("did not answer as ollama"))
        #expect(wrong.contains("switch runner/port"))
    }
}
