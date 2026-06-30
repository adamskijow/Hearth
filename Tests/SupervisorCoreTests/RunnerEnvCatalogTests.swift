// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

struct RunnerEnvCatalogTests {
    @Test func ollamaCatalogIsNonEmptyAndOmitsTheManagedHost() {
        let names = RunnerEnvCatalog.variables(for: "ollama").map(\.name)
        #expect(!names.isEmpty)
        // Hearth owns OLLAMA_HOST, so it must never be offered for hand-editing.
        #expect(!names.contains("OLLAMA_HOST"))
        #expect(names.contains("OLLAMA_KEEP_ALIVE"))
        // No duplicates, and every entry has an example for the placeholder.
        #expect(Set(names).count == names.count)
        #expect(RunnerEnvCatalog.variables(for: "ollama").allSatisfy { !$0.example.isEmpty })
    }

    @Test func unknownRunnerFallsBackToOllama() {
        // makeRunner treats anything not LM Studio or mlx as Ollama; the catalog
        // matches that default.
        #expect(RunnerEnvCatalog.variables(for: "something-else").map(\.name)
                == RunnerEnvCatalog.variables(for: "ollama").map(\.name))
    }

    @Test func lmStudioHasNoEnvCatalog() {
        #expect(RunnerEnvCatalog.variables(for: "lmstudio").isEmpty)
    }

    @Test func mlxOffersHuggingFaceCacheVars() {
        #expect(RunnerEnvCatalog.variables(for: "mlx").contains { $0.name == "HF_HOME" })
    }
}
