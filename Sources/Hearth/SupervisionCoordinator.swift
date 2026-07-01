// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Owns the engine's run loop so the menu and the control endpoint drive
/// supervision through one place. Begin starts supervising and ensures the loop
/// is running; end stops it and lets the loop wind down.
actor SupervisionCoordinator {
    let engine: SupervisorEngine

    init(engine: SupervisorEngine) {
        self.engine = engine
    }

    func begin() async {
        await engine.start()
        ensureLoop()
    }

    func end() async {
        await engine.stop()
    }

    func restart() async {
        await engine.restart()
        ensureLoop()
    }

    func status() async -> SupervisorState {
        await engine.snapshot()
    }

    func perform(_ command: ControlCommand) async {
        switch command {
        case .start: await begin()
        case .stop: await end()
        case .restart: await restart()
        case .status: break
        }
    }

    private func ensureLoop() {
        // engine.runLoop() no-ops when a loop is already running (its own `looping`
        // guard is the single source of truth), so it is always safe to spawn a task
        // here: a redundant one returns at once. This avoids the lost-wakeup race of
        // tracking a loopTask that is niled one await-hop after runLoop returns, in
        // which a begin/restart in that gap would skip starting the loop and leave a
        // freshly spawned runner unprobed.
        Task { [weak self] in await self?.engine.runLoop() }
    }
}
