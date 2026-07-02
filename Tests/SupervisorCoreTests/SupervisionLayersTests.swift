// SPDX-License-Identifier: MIT

import Testing
@testable import SupervisorCore

/// The doctor's supervision-layer report: which start-at-login layers are
/// installed, who holds the lock, and the warning when layers have stacked up.
struct SupervisionLayersTests {
    private func layers(root: Bool = false, agent: Bool = false, loginItem: Bool? = false,
                        pid: Int? = nil, alive: Bool = false) -> SupervisionLayers {
        SupervisionLayers(rootDaemonInstalled: root, userAgentInstalled: agent,
                          loginItemEnabled: loginItem, lockHolderPID: pid, lockHolderAlive: alive)
    }

    @Test func aSingleLayerIsReportedWithoutWarnings() {
        let report = layers(agent: true, pid: 5664, alive: true).report()
        #expect(report.diagnostics.isEmpty)
        #expect(report.lines.contains("supervision layer: login agent (com.hearth.headless)"))
        #expect(report.lines.contains("supervising instance: pid 5664 holds the lock"))
    }

    @Test func stackedLayersWarnAndNameEveryRemoval() {
        // The real pileup this Mac had: root daemon + login agent + login item.
        let report = layers(root: true, agent: true, loginItem: true, pid: 575, alive: true).report()
        #expect(report.diagnostics.count == 1)
        let message = report.diagnostics[0].message
        #expect(message.contains("3 supervision layers"))
        #expect(message.contains("hot standbys"))
        #expect(message.contains("sudo launchctl bootout system/com.hearth.daemon"))
        #expect(message.contains("hearth uninstall-agent"))
        #expect(message.contains("login item"))
        #expect(report.diagnostics[0].severity == .warning)
    }

    @Test func twoLayersAlsoWarnButOnlyNameTheInstalledRemovals() {
        let report = layers(root: true, agent: true, loginItem: false).report()
        let message = report.diagnostics[0].message
        #expect(message.contains("2 supervision layers"))
        #expect(!message.contains("login item"))
    }

    @Test func noLayersSaysHandStartedPlainly() {
        let report = layers().report()
        #expect(report.diagnostics.isEmpty)
        #expect(report.lines.contains { $0.contains("only when started by hand") })
    }

    @Test func aDeadLockHolderIsCalledOutNotCalledSupervising() {
        let report = layers(agent: true, pid: 999, alive: false).report()
        #expect(report.lines.contains { $0.contains("pid 999") && $0.contains("gone") })
        #expect(!report.lines.contains { $0.contains("holds the lock") })
    }

    @Test func noLockFileMeansNoOneSupervising() {
        let report = layers(agent: true).report()
        #expect(report.lines.contains { $0.contains("no instance holds the single-instance lock") })
    }

    @Test func anUndeterminedLoginItemIsSaidNotGuessed() {
        let report = layers(agent: true, loginItem: nil).report()
        #expect(report.lines.contains { $0.contains("could not be checked") })
        // And it does not count toward the stacked-layers warning.
        #expect(report.diagnostics.isEmpty)
    }
}
