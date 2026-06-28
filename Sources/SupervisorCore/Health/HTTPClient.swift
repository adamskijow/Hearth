// SPDX-License-Identifier: MIT

import Foundation

/// The outcome of a single HTTP GET. Deliberately coarse: the supervisor only
/// reads a runner's API to judge health, never to interpret content.
public enum HTTPOutcome: Sendable, Equatable {
    /// A 2xx response with its body.
    case ok(Data)
    /// A non 2xx response with its status code and body.
    case http(status: Int, body: Data)
    /// The request did not complete within the timeout. This is the signature of
    /// an alive but wedged runner: the socket is accepted but nothing answers.
    case timedOut
    /// The connection was refused. The listener is not up.
    case refused
    /// Any other transport failure, carrying a short description.
    case failure(String)
}

/// HTTP behind a protocol. The real implementation uses `URLSession`; the test
/// implementation returns scripted outcomes per URL with no network.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome
}
