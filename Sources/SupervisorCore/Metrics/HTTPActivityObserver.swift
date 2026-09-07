// SPDX-License-Identifier: MIT

import Foundation

/// Passive HTTP/1.1 framing observation (RFC 9112). Never edits forwarded bytes,
/// decodes bodies, or retains body content. Unsupported/ambiguous framing latches
/// unknown; it must never be interpreted as zero outstanding work.
public struct HTTPActivityObserver: Sendable {
    private enum Phase: Sendable {
        case headers, fixed(UInt64), chunkSize, chunk(UInt64), chunkEnd(Int), trailers, untilEOF
    }
    private struct Direction: Sendable {
        var phase: Phase = .headers
        var line: [UInt8] = []
        var lines: [String] = []
        var headerBytes = 0
        var started = false
    }
    private struct Request: Sendable {
        var head: Bool
        var bodyComplete: Bool
    }
    private var request = Direction()
    private var response = Direction()
    private var pending: [Request] = []
    public private(set) var unknown = false
    public private(set) var observedRequest = false
    public private(set) var completedRequests = 0
    public private(set) var sawBytes = false
    public init() {}

    public var activeRequests: Int {
        // The incomplete next request header is work even before its method is known.
        pending.count + ((request.started && isHeaders(request.phase)) ? 1 : 0)
    }
    public var isIdle: Bool { !unknown && activeRequests == 0 && !response.started }

    public mutating func ingestRequest(_ data: Data) { ingest(data, upstream: false) }
    public mutating func ingestResponse(_ data: Data) { ingest(data, upstream: true) }

    /// Only a clean upstream EOF completes a close-delimited response. A client
    /// write-half-close is allowed after a complete request, including while the
    /// response is still arriving. Premature EOF remains unresolved.
    public mutating func end(upstream: Bool, clean: Bool) {
        guard !unknown else { return }
        if !clean { if !isIdle { fail() }; return }
        if upstream {
            if case .untilEOF = response.phase { finish(upstream: true) }
            if !pending.isEmpty || response.started { fail() }
        } else if request.started { fail() }
    }

    private func isHeaders(_ phase: Phase) -> Bool {
        if case .headers = phase { return true }; return false
    }

    private mutating func fail() {
        unknown = true
        request = Direction()
        response = Direction()
        pending.removeAll()
    }

    private mutating func ingest(_ data: Data, upstream: Bool) {
        guard !data.isEmpty, !unknown else { return }
        sawBytes = true
        var cursor = data.startIndex
        while cursor < data.endIndex, !unknown {
            if upstream, pending.isEmpty { fail(); return }
            var direction = upstream ? response : request
            direction.started = true
            switch direction.phase {
            case .fixed(let remaining), .chunk(let remaining):
                let count = min(UInt64(data.endIndex - cursor), remaining)
                cursor += Int(count)
                let left = remaining - count
                if case .chunk = direction.phase {
                    direction.phase = left == 0 ? .chunkEnd(0) : .chunk(left)
                } else {
                    direction.phase = .fixed(left)
                }
                if upstream { response = direction } else { request = direction }
                if left == 0, case .fixed = direction.phase { finish(upstream: upstream) }
                continue
            case .untilEOF:
                if upstream { response = direction } else { fail() }
                return
            case .chunkEnd(let index):
                let expected: UInt8 = index == 0 ? 13 : 10
                guard data[cursor] == expected else { fail(); return }
                direction.phase = index == 0 ? .chunkEnd(1) : .chunkSize
            case .headers, .chunkSize, .trailers:
                let byte = data[cursor]
                direction.line.append(byte)
                direction.headerBytes += 1
                // Bounds apply to headers/trailers and each chunk-size line,
                // independent of body size or how the network fragments bytes.
                guard direction.headerBytes <= 65_536, direction.line.count <= 8192 else { fail(); return }
                if byte == 10 {
                    guard direction.line.count >= 2, direction.line[direction.line.count - 2] == 13 else { fail(); return }
                    let raw = direction.line.dropLast(2)
                    guard raw.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 < 127) }) else { fail(); return }
                    let line = String(decoding: raw, as: UTF8.self)
                    direction.line.removeAll(keepingCapacity: true)
                    switch direction.phase {
                    case .headers:
                        if !line.isEmpty { direction.lines.append(line) }
                    case .chunkSize:
                        // Extensions are not needed by supported runner clients.
                        // An extension falls back to unknown without affecting relay.
                        guard !line.isEmpty, line.allSatisfy({ $0.isHexDigit }),
                              let size = UInt64(line, radix: 16) else { fail(); return }
                        direction.headerBytes = 0
                        direction.phase = size == 0 ? .trailers : .chunk(size)
                    case .trailers:
                        if !line.isEmpty, !Self.validHeader(line) { fail(); return }
                    default: break
                    }
                    if upstream { response = direction } else { request = direction }
                    if line.isEmpty {
                        if case .headers = direction.phase { parseHeaders(upstream: upstream) }
                        else if case .trailers = direction.phase { finish(upstream: upstream) }
                    }
                    cursor += 1
                    continue
                }
            }
            if upstream { response = direction } else { request = direction }
            cursor += 1
        }
    }

    private static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || Array("!#$%&'*+-.^_`|~".utf8).contains($0)
        }
    }
    private static func validHeader(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        return token(String(line[..<colon]))
    }

    private mutating func parseHeaders(upstream: Bool) {
        var direction = upstream ? response : request
        guard let first = direction.lines.first else { fail(); return }
        var headers: [String: [String]] = [:]
        for line in direction.lines.dropFirst() {
            guard Self.validHeader(line), let colon = line.firstIndex(of: ":") else { fail(); return }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }
        // Strict subset: conflicting/duplicate lengths, transfer codings, upgrades
        // and tunnels remain opaque rather than risking request desynchronization.
        let lengths = headers["content-length"] ?? []
        let transfers = headers["transfer-encoding"] ?? []
        guard lengths.count <= 1, transfers.count <= 1,
              lengths.isEmpty || transfers.isEmpty,
              headers["upgrade"] == nil,
              !(headers["connection"] ?? []).joined(separator: ",").lowercased().contains("upgrade")
        else { fail(); return }
        var length: UInt64?
        if let raw = lengths.first {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = UInt64(raw)
            else { fail(); return }
            length = parsed
        }
        if let transfer = transfers.first, transfer.lowercased() != "chunked" { fail(); return }
        var bodyless = false
        if upstream {
            let parts = first.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
                  parts[1].count == 3, let status = Int(parts[1]), (100...599).contains(status),
                  let oldest = pending.first else { fail(); return }
            if (100...199).contains(status) {
                guard status != 101, length == nil, transfers.isEmpty else { fail(); return }
                response = Direction()
                return
            }
            // An early final response is relayed, but no idleness is inferred
            // while request upload and server rejection overlap.
            guard oldest.bodyComplete else { fail(); return }
            bodyless = oldest.head || status == 204 || status == 304
        } else {
            let parts = first.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, Self.token(String(parts[0])), parts[0] != "CONNECT",
                  parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
                  parts[1].first == "/" || parts[1] == "*",
                  parts[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }), pending.count < 32 else { fail(); return }
            pending.append(Request(head: parts[0] == "HEAD", bodyComplete: false))
            observedRequest = true
            bodyless = length == nil && transfers.isEmpty
        }
        direction.lines.removeAll()
        direction.headerBytes = 0
        direction.phase = !transfers.isEmpty ? .chunkSize
            : (length.map { .fixed($0) } ?? .untilEOF)
        if upstream { response = direction } else { request = direction }
        if bodyless || length == 0 { finish(upstream: upstream) }
    }

    private mutating func finish(upstream: Bool) {
        if upstream {
            guard !pending.isEmpty, pending[0].bodyComplete else { fail(); return }
            pending.removeFirst()
            completedRequests = min(completedRequests, Int.max - 1) + 1
            response = Direction()
        } else {
            guard !pending.isEmpty else { fail(); return }
            pending[pending.count - 1].bodyComplete = true
            request = Direction()
        }
    }
}
