// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import SupervisorCore

/// The control endpoint's routing and auth are pure, so they are tested here
/// without any sockets.
struct ControlRoutingTests {
    private let token = "s3cret-topic-token"
    private let state = SupervisorState(phase: .healthy, residentModels: [ResidentModel(name: "llama3")])
    private let now = Date(timeIntervalSince1970: 1000)

    private func bearer(_ value: String) -> String { "Bearer \(value)" }

    @Test func routesKnownMethodsAndPaths() {
        #expect(ControlRouting.command(method: "GET", path: "/status") == .status)
        #expect(ControlRouting.command(method: "GET", path: "/") == .status)
        #expect(ControlRouting.command(method: "POST", path: "/start") == .start)
        #expect(ControlRouting.command(method: "POST", path: "/stop") == .stop)
        #expect(ControlRouting.command(method: "POST", path: "/restart") == .restart)
        #expect(ControlRouting.command(method: "GET", path: "/status?x=1") == .status)
    }

    @Test func rejectsUnknownRoutes() {
        #expect(ControlRouting.command(method: "POST", path: "/status") == nil)
        #expect(ControlRouting.command(method: "GET", path: "/start") == nil)
        #expect(ControlRouting.command(method: "DELETE", path: "/") == nil)
    }

    @Test func authorizationRequiresExactBearerToken() {
        #expect(ControlRouting.isAuthorized(bearer(token), token: token))
        #expect(!ControlRouting.isAuthorized(bearer("wrong"), token: token))
        #expect(!ControlRouting.isAuthorized(token, token: token)) // missing "Bearer "
        #expect(!ControlRouting.isAuthorized(nil, token: token))
        #expect(!ControlRouting.isAuthorized(bearer(""), token: ""))   // empty token never authorizes
    }

    @Test func unauthorizedWithoutAGoodToken() {
        let outcome = ControlRouting.handle(
            method: "GET", path: "/status", authorization: bearer("nope"),
            token: token, state: state, now: now
        )
        #expect(outcome == .unauthorized)
    }

    @Test func statusReturnsShapedJSON() throws {
        let outcome = ControlRouting.handle(
            method: "GET", path: "/status", authorization: bearer(token),
            token: token, state: state, now: now
        )
        guard case .status(let data) = outcome else {
            Issue.record("expected status outcome")
            return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["phase"] as? String == "healthy")
        #expect((object["models"] as? [String]) == ["llama3"])
    }

    @Test func commandsBecomePerformOutcomes() {
        let start = ControlRouting.handle(
            method: "POST", path: "/start", authorization: bearer(token),
            token: token, state: state, now: now
        )
        #expect(start == .perform(.start))

        let restart = ControlRouting.handle(
            method: "POST", path: "/restart", authorization: bearer(token),
            token: token, state: state, now: now
        )
        #expect(restart == .perform(.restart))
    }

    @Test func unknownPathIsNotFoundWhenAuthorized() {
        let outcome = ControlRouting.handle(
            method: "GET", path: "/nope", authorization: bearer(token),
            token: token, state: state, now: now
        )
        #expect(outcome == .notFound)
    }
}
