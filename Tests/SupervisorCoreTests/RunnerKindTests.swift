// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

/// RunnerKind is the one place the config `runner` aliases are matched. These pin
/// the mapping (including the historic default-to-ollama for anything unknown) that
/// every per-runner switch across the codebase now routes through.
struct RunnerKindTests {
    @Test func mapsAliasesAndDefaultsUnknownToOllama() {
        for raw in ["ollama", "Ollama", "OLLAMA", "", "not-a-runner"] {
            #expect(RunnerKind(fromConfigString: raw) == .ollama)
        }
        for raw in ["lmstudio", "lm-studio", "lm_studio", "LMStudio"] {
            #expect(RunnerKind(fromConfigString: raw) == .lmStudio)
        }
        for raw in ["mlx", "mlx_lm", "mlx-lm", "MLX"] {
            #expect(RunnerKind(fromConfigString: raw) == .mlx)
        }
    }

    @Test func exposesDisplayAndInstallData() {
        #expect(RunnerKind.ollama.displayName == "Ollama")
        #expect(RunnerKind.lmStudio.displayName == "LM Studio")
        #expect(RunnerKind.mlx.displayName == "mlx_lm")
        #expect(RunnerKind.ollama.installHint == "brew install ollama")
        #expect(RunnerKind.lmStudio.installHint == "brew install --cask lm-studio")
        #expect(RunnerKind.mlx.installHint == "pip install mlx-lm")
    }

    @Test func configExposesRunnerKind() {
        #expect(HearthConfig(runner: "lm-studio").runnerKind == .lmStudio)
        #expect(HearthConfig(runner: "mlx_lm").runnerKind == .mlx)
        #expect(HearthConfig(runner: "ollama").runnerKind == .ollama)
    }
}
