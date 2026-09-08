// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore
import Testing
@testable import Hearth

struct EndpointAdmissionTests {
    @Test(arguments: ["127.0.0.1/path", "user@localhost", "localhost?x", "localhost#x", "localhost:1234", "https://localhost", " localhost", "localhost\n", "[abc]", "::1\u{0}/path", "999.0.0.1", "a..b", "-host"])
    func rejectsURLPartsAsHost(_ host: String) {
        #expect(!isValidEndpointHost(host))
        #expect(ConfigDiagnostics.check(HearthConfig(host: host)).contains { $0.severity == .error })
    }

    @Test(arguments: ["localhost", "runner.tailnet.ts.net", "127.0.0.1", "0.0.0.0", "::", "::1", "[::1]", "2001:db8::1"])
    func acceptsHostnamesAndIPAddresses(_ host: String) {
        #expect(isValidEndpointHost(host))
    }

    @Test func recordedProcessOnOnePortDoesNotOwnAnotherListener() throws {
        func listener() throws -> (Process, Int) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", "-c", "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1],flush=True); time.sleep(30)"]
            process.standardOutput = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            guard let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                process.terminate(); process.waitUntilExit()
                throw CocoaError(.fileReadCorruptFile)
            }
            return (process, port)
        }
        let (owned, ownedPort) = try listener()
        defer { owned.terminate(); owned.waitUntilExit() }
        let (foreign, foreignPort) = try listener()
        defer { foreign.terminate(); foreign.waitUntilExit() }
        let record = try #require(RunnerStateStore.liveIdentity(pid: owned.processIdentifier))
        #expect(ListenerOwnership.recordedOwner(addresses: ["127.0.0.1"], port: ownedPort, records: [record]) == record)
        #expect(ListenerOwnership.recordedOwner(addresses: ["127.0.0.1"], port: foreignPort, records: [record]) == nil)
        let otherRecord = try #require(RunnerStateStore.liveIdentity(pid: foreign.processIdentifier))
        #expect(ListenerOwnership.recordedOwner(addresses: ["127.0.0.1"], port: ownedPort, records: [record, otherRecord]) == record)
    }

    @Test func listenerEvidenceMustMatchPIDAddressPortAndFamily() {
        let sockets = "p42\ntIPv4\nn127.0.0.1:11434\np43\ntIPv6\nn*:12434\n"
        #expect(ListenerOwnership.owns(sockets, pid: 42, address: "127.0.0.1", port: 11434))
        #expect(!ListenerOwnership.owns(sockets, pid: 42, address: "127.0.0.1", port: 12434))
        #expect(!ListenerOwnership.owns(sockets, pid: 42, address: "127.0.0.2", port: 11434))
        #expect(!ListenerOwnership.owns(sockets, pid: 43, address: "127.0.0.1", port: 12434))
        #expect(ListenerOwnership.owns(sockets, pid: 43, address: "::1", port: 12434))
        let wildcard = "p42\ntIPv4\nn*:11434\n"
        #expect(ListenerOwnership.owns(wildcard, pid: 42, address: "127.0.0.1", port: 11434, localAddresses: []))
        #expect(!ListenerOwnership.owns(wildcard, pid: 42, address: "192.0.2.9", port: 11434, localAddresses: []))
    }
}
