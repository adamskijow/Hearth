// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerManagerConflictTests {
    @Test func warnsWhenBrewServicesAlsoManagesOllamaInManagedMode() {
        let warning = RunnerManagerConflict.warning(
            runner: "ollama", mode: "managed",
            loadedLabels: ["homebrew.mxcl.ollama", "com.apple.something"])
        #expect(warning?.contains("brew services stop ollama") == true)
        #expect(warning?.contains("hearth mode attached") == true)
        #expect(RunnerManagerConflict.competingLabel(
            runner: "ollama", loadedLabels: ["homebrew.mxcl.ollama"]) == "homebrew.mxcl.ollama")
    }

    @Test func attachedModeIsFine() {
        // Attached mode is meant to watch a runner something else started.
        #expect(RunnerManagerConflict.warning(
            runner: "ollama", mode: "attached", loadedLabels: ["homebrew.mxcl.ollama"]) == nil)
    }

    @Test func noWarningWithoutTheCompetingLabel() {
        #expect(RunnerManagerConflict.warning(
            runner: "ollama", mode: "managed", loadedLabels: ["com.apple.something"]) == nil)
    }

    @Test func noWarningForRunnersBrewServicesDoesNotManage() {
        #expect(RunnerManagerConflict.warning(
            runner: "mlx", mode: "managed", loadedLabels: ["homebrew.mxcl.ollama"]) == nil)
        #expect(RunnerManagerConflict.warning(
            runner: "lmstudio", mode: "managed", loadedLabels: ["homebrew.mxcl.ollama"]) == nil)
    }
}
