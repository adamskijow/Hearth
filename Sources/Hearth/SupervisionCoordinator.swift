// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

/// Owns the engine's run loop so the menu and the control endpoint drive
/// supervision through one place. Begin starts supervising and ensures the loop
/// is running; end stops it and lets the loop wind down.
actor SupervisionCoordinator {
    let engine: SupervisorEngine
    private var loopTask: Task<Void, Never>?

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
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.engine.runLoop()
            await self?.loopFinished()
        }
    }

    private func loopFinished() {
        loopTask = nil
    }
}
