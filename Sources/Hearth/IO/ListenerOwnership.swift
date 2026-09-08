// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import SupervisorCore

/// A live recorded PID alone does not establish ownership of a particular port.
/// Match every reachable address to that process's listening sockets instead.
enum ListenerOwnership {
    static func reachableAddresses(host: String, port: Int) -> [String] {
        guard isValidEndpointHost(host), (1...65_535).contains(port) else { return [] }
        var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
            ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(probeHost(for: host), String(port), &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }
        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer,
                                   socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.insert(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
                    }
                }
                close(fd)
            }
            cursor = info.pointee.ai_next
        }
        return addresses.sorted()
    }

    static func recordedOwner(addresses: [String], port: Int,
                              records: [RunnerProcessIdentity] = RunnerStateStore.loadRecorded()) -> RunnerProcessIdentity? {
        let local = localInterfaceAddresses()
        guard !addresses.isEmpty, addresses.allSatisfy({ isLocal($0, interfaces: local) }) else { return nil }
        let live = records.filter { RunnerSweep.shouldSweep(recorded: $0, live: RunnerStateStore.liveIdentity(pid: $0.pid)) }
        guard !live.isEmpty, live.count <= 64 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", live.map { String($0.pid) }.joined(separator: ","),
                             "-iTCP:\(port)", "-sTCP:LISTEN", "-Fptn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + 2) == .timedOut {
            // Only this helper process is signalled. Incomplete evidence is unknown.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let sockets = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let owned = live.filter {
            RunnerSweep.shouldSweep(recorded: $0, live: RunnerStateStore.liveIdentity(pid: $0.pid))
        }
        guard addresses.allSatisfy({ address in
            owned.contains { owns(sockets, pid: $0.pid, address: address, port: port, localAddresses: local) }
        }) else { return nil }
        return owned.last { record in
            addresses.contains { owns(sockets, pid: record.pid, address: $0, port: port, localAddresses: local) }
        }
    }

    static func localInterfaceAddresses() -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result = Set<String>()
        var cursor = list
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr,
               address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                               socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.insert(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }

    private static func isLocal(_ address: String, interfaces: Set<String>) -> Bool {
        interfaces.contains(address) || address == "::1"
            || (address.hasPrefix("127.") && isValidEndpointHost(address))
    }

    static func owns(_ output: String, pid: Int32, address: String, port: Int,
                     localAddresses: Set<String> = localInterfaceAddresses()) -> Bool {
        guard isLocal(address, interfaces: localAddresses) else { return false }
        var currentPID: Int32?
        var family = ""
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": currentPID = Int32(line.dropFirst()); family = ""
            case "t": family = String(line.dropFirst())
            case "n" where currentPID == pid:
                let name = String(line.dropFirst())
                if name == "\(urlAuthorityHost(for: address)):\(port)" { return true }
                if name == "*:\(port)", family == (address.contains(":") ? "IPv6" : "IPv4") { return true }
            default: break
            }
        }
        return false
    }
}
