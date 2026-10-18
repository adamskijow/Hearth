// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import SupervisorCore
import Testing
@testable import Hearth

private struct IdleProcesses: ProcessControlling {
    func spawn(_ spec: ProcessSpec) throws -> ProcessHandleID { throw CocoaError(.executableNotLoadable) }
    func status(_ id: ProcessHandleID) -> ProcessStatus { ProcessStatus(isAlive: false) }
    func terminate(_ id: ProcessHandleID) {}
    func executableFingerprint(at url: URL) -> String? { nil }
}

private struct ReadyHTTP: HTTPClient {
    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        .ok(Data((url.path == "/api/ps" ? #"{"models":[]}"# : #"{"version":"fixture"}"#).utf8))
    }
    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome { .refused }
}

private final class ControlReload: @unchecked Sendable {
    private let lock = NSLock()
    private var server: ControlServer?
    private var ended = false
    func set(_ server: ControlServer) { lock.withLock { self.server = server } }
    func stop() { lock.withLock { server }?.stop() }
    func didEnd() { lock.withLock { ended = true } }
    var hasEnded: Bool { lock.withLock { ended } }
}

struct ControlLifecycleTests {
    @Test(arguments: [false, true])
    func pendingRequestCannotRestartAStoppedServer(retireEngine: Bool) async throws {
        let port = try unusedLoopbackPort()
        let engine = SupervisorEngine(clock: SystemClock(), processes: IdleProcesses(),
            http: ReadyHTTP(), runner: OllamaRunner(binaryPath: "/unused", host: "127.0.0.1", port: 9),
            power: NoopPowerManager(), notifier: CompositeNotifier([]),
            policy: RestartPolicyConfig(), managed: false)
        let coordinator = SupervisionCoordinator(engine: engine)
        await engine.start()
        let reload = ControlReload()
        let candidate = ControlServer(host: "127.0.0.1", port: port, token: "isolated-fixture-token",
            coordinator: coordinator, onControlAction: { _, _ in
                // Interleave teardown after the transport's initial stop check,
                // before the command hops to the coordinator and engine actors.
                reload.stop()
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    if retireEngine { await coordinator.retire() }
                    else { await coordinator.end() }
                    reload.didEnd()
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 2)
            })
        let server = try #require(candidate)
        defer { server.stop() }
        reload.set(server)
        server.start()
        let client = URLSessionHTTPClient()
        let base = "http://127.0.0.1:\(port)"
        var ready = false
        for _ in 0..<100 {
            if case .ok = await client.get(URL(string: base + "/healthz")!, timeout: 0.2) {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready)
        var request = URLRequest(url: URL(string: base + "/start")!)
        request.httpMethod = "POST"
        request.setValue("Bearer isolated-fixture-token", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2
        _ = try? await URLSession.shared.data(for: request)
        #expect(await eventually { reload.hasEnded })
        // Give the already accepted request a chance to resume after teardown.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await engine.snapshot().phase == .stopped)
        // A replacement control server may use the same engine after a live
        // reload, but a permanently retired engine rejects that too.
        let accepted = await coordinator.perform(.start)
        #expect(accepted == !retireEngine)
        await coordinator.end()
    }

    private func unusedLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        try #require(bound == 0)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        try #require(named == 0)
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
