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
        // GET / is the browser status page, handled before command(), not a command.
        #expect(ControlRouting.command(method: "GET", path: "/") == nil)
        #expect(ControlRouting.command(method: "POST", path: "/start") == .start)
        #expect(ControlRouting.command(method: "POST", path: "/stop") == .stop)
        #expect(ControlRouting.command(method: "POST", path: "/restart") == .restart)
        #expect(ControlRouting.command(method: "GET", path: "/status?x=1") == .status)
    }

    @Test func rootServesTheBrowserPageUnauthenticated() {
        // GET / returns the HTML shell with no token (it reveals nothing and
        // fetches /status itself), while /status still needs the token.
        let page = ControlRouting.handle(
            method: "GET", path: "/", authorization: nil,
            token: token, state: state, now: now
        )
        guard case .html(let data) = page else {
            Issue.record("expected html outcome for GET /")
            return
        }
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("<title>Hearth</title>"))
        #expect(body.contains("/status"))
        // The page must not embed any token.
        #expect(!body.contains(token))
        // Status values (model names from the runner) are escaped before they go
        // into innerHTML, so a hostile model name cannot inject script on the page
        // that holds the bearer token. Guard that the escaper exists and is used.
        #expect(body.contains("function esc("))
        #expect(body.contains("esc(v)"))
        #expect(body.contains("id=\"restart\""))
        #expect(body.contains("fetch('/' + name"))
        #expect(body.contains("confirm("))
        // /status without a token is still rejected.
        let status = ControlRouting.handle(
            method: "GET", path: "/status", authorization: nil,
            token: token, state: state, now: now
        )
        #expect(status == .unauthorized)
    }

    @Test func statusKeySetIsTheStabilityContract() throws {
        // docs/stability.md declares /status fields stable and additive-only.
        // This pins the exact key set with every optional source populated, so
        // a rename or removal is a deliberate act that edits this test (and the
        // contract), never an accident.
        let full = SupervisorState(phase: .healthy, residentModels: [ResidentModel(name: "m")],
                                   healthySince: now.addingTimeInterval(-60), lastRestartReason: "crash",
                                   restartCount: 1, busy: true, lastDownCategory: "crash",
                                   lastRestartCategory: "crash", deepProbeConfigured: true,
                                   oversizedModels: ["big:70b"])
        let metrics = SystemMetrics(thermal: .nominal, memoryUsedFraction: 0.5, runnerResidentBytes: 1024)
        let tokens = TokenMetricsStore.Snapshot(
            generationRequests: 1, generationTokensTotal: 10, lastTokensPerSecond: 5)
        let data = ControlRouting.statusJSON(
            full, now: now, runnerKind: "ollama", metrics: metrics, tokens: tokens,
            recentEvents: ["2026-07-09 12:00:00  Recovered"])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "phase", "runner", "busy", "models", "uptimeSeconds", "restartCount",
            "consecutiveFailures", "lastRestartReason", "lastDownCategory",
            "lastRestartCategory", "oversizedModels", "deepProbeConfigured", "thermal",
            "memoryUsedPercent", "runnerResidentBytes", "tokensPerSecond", "generationTokensTotal",
            "recentEvents",
        ])
        #expect(object["runner"] as? String == "ollama")
        #expect(object["lastRestartCategory"] as? String == "crash")
        #expect(object["oversizedModels"] as? [String] == ["big:70b"])
        // Absent, not empty, when no model is flagged.
        let clean = ControlRouting.statusJSON(SupervisorState(phase: .healthy), now: now, runnerKind: "ollama")
        let cleanObject = try #require(try JSONSerialization.jsonObject(with: clean) as? [String: Any])
        #expect(cleanObject["oversizedModels"] == nil)
        #expect(cleanObject["recentEvents"] == nil)
    }

    @Test func statusCanCarryBoundedRecentActivityForThePhone() throws {
        let data = ControlRouting.statusJSON(
            state, now: now, recentEvents: ["2026-07-09 12:00:00  Recovered"])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["recentEvents"] as? [String] == ["2026-07-09 12:00:00  Recovered"])
    }

    @Test func prometheusCarriesRunnerInfoAndRestartCategory() {
        let state = SupervisorState(phase: .healthy, restartCount: 1, lastRestartCategory: "maintenance")
        let text = String(decoding: ControlRouting.prometheusText(state, now: now, runnerKind: "mlx"), as: UTF8.self)
        #expect(text.contains("hearth_runner_info{runner=\"mlx\"} 1"))
        #expect(text.contains("hearth_last_restart{category=\"maintenance\"} 1"))
        // Absent until the first restart this session.
        let fresh = String(decoding: ControlRouting.prometheusText(SupervisorState(phase: .healthy), now: now, runnerKind: "ollama"), as: UTF8.self)
        #expect(fresh.contains("hearth_runner_info{runner=\"ollama\"} 1"))
        #expect(!fresh.contains("hearth_last_restart"))
    }

    @Test func statusJSONCarriesTheNewSurfacedFields() throws {
        let busy = SupervisorState(phase: .healthy, restartCount: 2,
                                   busy: true, lastDownCategory: "oom", deepProbeConfigured: true)
        let tokens = TokenMetricsStore.Snapshot(
            generationRequests: 4, generationTokensTotal: 512, lastTokensPerSecond: 42.57)
        let data = ControlRouting.statusJSON(busy, now: now, metrics: nil, tokens: tokens)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["busy"] as? Bool == true)
        #expect(object["lastDownCategory"] as? String == "oom")
        #expect(object["deepProbeConfigured"] as? Bool == true)
        #expect(object["generationTokensTotal"] as? Int == 512)
        // Throughput is rounded to one decimal for display.
        let rate = try #require(object["tokensPerSecond"] as? Double)
        #expect(rate == 42.6)

        // With no proxy, the throughput fields are simply absent.
        let plain = ControlRouting.statusJSON(SupervisorState(phase: .healthy), now: now)
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(plainObject["tokensPerSecond"] == nil)
        #expect(plainObject["busy"] as? Bool == false)
    }

    @Test func namedTokensAuthorizeAndIdentifyTheActor() {
        let named = [ControlToken(name: "phone-kitchen", secret: "kitchen-secret-long-enough"),
                     ControlToken(name: "laptop", secret: "laptop-secret-long-enough")]
        // The primary token authorizes as "default".
        #expect(ControlRouting.authenticate(bearer(token), token: token, namedTokens: named) == "default")
        // A named token authorizes as its name.
        #expect(ControlRouting.authenticate(bearer("laptop-secret-long-enough"), token: token, namedTokens: named) == "laptop")
        #expect(ControlRouting.authenticate(bearer("phone-kitchen"), token: token, namedTokens: named) == nil)  // the NAME is not the secret
        // A wrong secret authorizes as nothing.
        #expect(ControlRouting.authenticate(bearer("nope"), token: token, namedTokens: named) == nil)
        #expect(ControlRouting.authenticate(nil, token: token, namedTokens: named) == nil)
        // isAuthorized agrees, and a named token opens the perform routes.
        #expect(ControlRouting.isAuthorized(bearer("laptop-secret-long-enough"), token: token, namedTokens: named))
        #expect(ControlRouting.earlyOutcome(method: "POST", path: "/restart",
            authorization: bearer("laptop-secret-long-enough"), token: token, namedTokens: named) == .perform(.restart))
    }

    @Test func auditMessageNamesCommandAndActor() {
        #expect(EventLog.auditMessage(command: "restart", actor: "phone-kitchen")
                == "Control: restart requested by token \"phone-kitchen\"")
    }

    @Test func statusPageRendersBusyAndThroughput() {
        let page = String(decoding: Data(ControlStatusPage.html.utf8), as: UTF8.self)
        #expect(page.contains("(busy)"))
        #expect(page.contains("tok/s"))
        #expect(page.contains("last failure"))
    }

    @Test func earlyOutcomeResolvesEverythingButAuthenticatedStatus() {
        // Routes that need no supervisor state are resolved without it, so the
        // server can answer them without sampling metrics.
        func early(_ method: String, _ path: String, auth: String? = nil) -> ControlOutcome? {
            ControlRouting.earlyOutcome(method: method, path: path, authorization: auth, token: token)
        }
        if case .status = early("GET", "/healthz") {} else { Issue.record("healthz should resolve early") }
        if case .html = early("GET", "/") {} else { Issue.record("/ should resolve to the page early") }
        #expect(early("GET", "/status", auth: nil) == .unauthorized)
        #expect(early("POST", "/start", auth: bearer(token)) == .perform(.start))
        #expect(early("GET", "/nope", auth: bearer(token)) == .notFound)
        // Only an authenticated /status needs live state, so it defers (nil).
        #expect(early("GET", "/status", auth: bearer(token)) == nil)
    }

    @Test func metricsRequiresAuthAndReturnsPrometheus() {
        // Like /status, /metrics needs the token.
        #expect(ControlRouting.handle(method: "GET", path: "/metrics", authorization: nil,
                                      token: token, state: state, now: now) == .unauthorized)
        let outcome = ControlRouting.handle(method: "GET", path: "/metrics", authorization: bearer(token),
                                            token: token, state: state, now: now)
        guard case .prometheus(let data) = outcome else {
            Issue.record("expected a prometheus outcome")
            return
        }
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("hearth_up 1"))
        #expect(body.contains("hearth_phase{phase=\"healthy\"} 1"))
        #expect(body.contains("# TYPE hearth_restarts_total counter"))
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

    @Test func healthzIsAnUnauthenticatedOK() throws {
        // No token at all still returns 200 with a minimal body, and never the
        // supervisor state.
        for auth in [nil, bearer("nope"), bearer(token)] as [String?] {
            let outcome = ControlRouting.handle(
                method: "GET", path: "/healthz", authorization: auth,
                token: token, state: state, now: now
            )
            guard case .status(let data) = outcome else {
                Issue.record("expected a 200 status outcome for /healthz")
                return
            }
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["status"] as? String == "ok")
            #expect(object["phase"] == nil)  // leaks no supervisor state
        }
        #expect(ControlRouting.isHealthCheck(method: "GET", path: "/healthz?x=1"))
        #expect(!ControlRouting.isHealthCheck(method: "POST", path: "/healthz"))
    }
}
