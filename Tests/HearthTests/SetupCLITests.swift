// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore
import Testing
@testable import Hearth

private final class SetupFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var observed: [String] { lock.withLock { calls } }
    func record(_ call: String) { lock.withLock { calls.append(call) } }
    func dependencies(installOK: Bool = true, ready: Bool = true, exists: Bool = true,
                      probe: StatusCLI.RunnerPortProbe = .init(portOccupied: false, compatibleRunnerReady: false, hearthRunner: nil),
                      labels: Set<String> = [], saveOK: Bool = true) -> SetupCLI.Dependencies {
        .init(executable: { self.record("path:\($0)"); return exists },
              loadedLabels: { labels }, portProbe: { _ in probe },
              save: { _ in self.record("save"); return saveOK },
              install: { self.record("install"); return .init(ok: installOK, lines: []) },
              ready: { config, _ in self.record("ready:\(config.port)"); return ready },
              inference: { _, _ in self.record("inference") })
    }
}

struct SetupCLITests {
    private func load(_ config: HearthConfig = HearthConfig(), created: Bool = false, problem: Bool = false) -> ConfigLoad {
        ConfigLoad(config: config, note: problem ? "Cannot read configuration." : nil, isProblem: problem, createdDefault: created)
    }

    @Test func malformedAndInvalidConfigsNeverInstallOrSave() async {
        for input in [load(problem: true), load(HearthConfig(runner: "mlx", port: 8080))] {
            let fixture = SetupFixture()
            let result = await SetupCLI.perform(load: input, options: .init(), dependencies: fixture.dependencies())
            #expect(!result.ok)
            #expect(fixture.observed.isEmpty)
        }
    }

    @Test func preservesConfiguredExecutableAndStopsAtEachFailure() async {
        var config = HearthConfig()
        config.ollamaBinaryPath = "/custom/ollama"
        for (exists, installed, ready, expected) in [
            (false, true, true, ["path:/custom/ollama"]),
            (true, false, true, ["path:/custom/ollama", "install"]),
            (true, true, false, ["path:/custom/ollama", "install", "ready:11434"])
        ] {
            let fixture = SetupFixture()
            let result = await SetupCLI.perform(load: load(config), options: .init(),
                dependencies: fixture.dependencies(installOK: installed, ready: ready, exists: exists))
            #expect(!result.ok)
            #expect(fixture.observed == expected)
        }
    }

    @Test func checkModeUsesClientEndpointAndNeverInstallsOrSaves() async {
        var config = HearthConfig()
        config.metricsProxyEnabled = true
        config.metricsProxyPort = 12436
        let fixture = SetupFixture()
        let result = await SetupCLI.perform(load: load(config), options: .init(checkOnly: true, model: "workload"),
            dependencies: fixture.dependencies(exists: false))
        #expect(result.ok)
        #expect(fixture.observed == ["ready:12436", "inference"])
        #expect(result.lines.contains { $0.contains("visibility is partial") })
    }

    @Test func checkDoesNotInventMissingConfigOrClaimUntestedInference() async {
        let fixture = SetupFixture()
        let missing = await SetupCLI.perform(load: load(created: true), options: .init(checkOnly: true), dependencies: fixture.dependencies())
        #expect(!missing.ok)
        #expect(fixture.observed.isEmpty)
        let shallow = await SetupCLI.perform(load: load(), options: .init(checkOnly: true), dependencies: fixture.dependencies())
        #expect(shallow.ok)
        #expect(shallow.lines.contains { $0.contains("Inference has not been tested") })
    }

    @Test func attachedDoesNotNeedLocalExecutableAndReportsObservation() async {
        let fixture = SetupFixture()
        let result = await SetupCLI.perform(load: load(HearthConfig(mode: "attached")), options: .init(), dependencies: fixture.dependencies(exists: false))
        #expect(result.ok)
        #expect(fixture.observed == ["install", "ready:11434"])
        #expect(result.lines.contains { $0.contains("cannot restart") })
    }

    @Test func freshAttachedChoiceMustPersistBeforeInstallation() async {
        let fixture = SetupFixture()
        let result = await SetupCLI.perform(load: load(created: true), options: .init(), dependencies: fixture.dependencies(
            probe: .init(portOccupied: true, compatibleRunnerReady: true, hearthRunner: nil), labels: ["homebrew.mxcl.ollama"], saveOK: false))
        #expect(!result.ok)
        #expect(fixture.observed == ["save"])
    }

    @Test func inferenceFailureFailsSetup() async {
        let fixture = SetupFixture()
        var dependencies = fixture.dependencies()
        dependencies.inference = { _, _ in throw RunnerProbeSetup.SetupError.http(404) }
        let result = await SetupCLI.perform(load: load(), options: .init(checkOnly: true, model: "missing"), dependencies: dependencies)
        #expect(!result.ok)
        #expect(result.lines.last?.contains("404") == true)
    }

    @Test func installerCarriesOnlyRequiredIsolationEnvironment() {
        #expect(AgentInstaller.launchEnvironment(config: "/tmp/config.json", inherited: [
            "HEARTH_DATA_DIR": "/tmp/data", "UNRELATED_SECRET": "never-copy"
        ]) == ["HEARTH_CONFIG": "/tmp/config.json", "HEARTH_DATA_DIR": "/tmp/data"])
    }

    @Test func starterWriteFailureIsBlocking() throws {
        let parent = TestIsolation.path("not-a-directory")
        try Data("file".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let loaded = ConfigStore.load(from: parent.appendingPathComponent("config.json"))
        #expect(loaded.isProblem)
        #expect(!loaded.createdDefault)
        #expect(!loaded.blockingDiagnostics().isEmpty)
    }
}
