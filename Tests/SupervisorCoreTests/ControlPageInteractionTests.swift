// SPDX-License-Identifier: MIT

import Foundation
import JavaScriptCore
import Testing
@testable import SupervisorCore

/// Execute the shipped script against a small DOM fixture, without a browser or
/// network. These checks exercise authentication transitions and pending work.
struct ControlPageInteractionTests {
    @Test func connectionAndReadOnlyAccess() throws {
        try run("""
        tok.value = 'fixture';
        await refresh();
        check(!access.open, 'connected credentials should collapse');
        check(!elements.actions.hidden, 'control access should show actions');
        check(elements.status.innerHTML.includes('&lt;model&gt;'), 'status must escape model names');
        access.open = true;
        await refresh();
        check(access.open, 'polling should leave credential editing open');
        state.credentialAccess = 'statusOnly';
        await refresh();
        check(elements.actions.hidden, 'read-only access must hide actions');
        elements.forget.listeners.click();
        check(elements.status.innerHTML === '', 'forget must remove private status');
        check(elements.actions.hidden && access.open, 'forget must return to connection setup');
        check(sessionStorage.getItem('hearthToken') === null, 'forget must remove the stored token');
        """)
    }

    @Test func lateStatusCannotRestoreForgottenData() throws {
        try run("""
        tok.value = 'fixture';
        let release;
        fetch = () => new Promise(resolve => { release = resolve; });
        const pending = refresh();
        elements.forget.listeners.click();
        release({ ok:true, json:async () => state });
        await pending;
        check(elements.status.innerHTML === '', 'a late response must not restore forgotten status');
        check(elements.actions.hidden && access.open, 'a late response must not reconnect');
        """)
    }

    @Test func monitoringActionsAndConnectionFailure() throws {
        try run("""
        tok.value = 'fixture';
        state.mode = 'attached';
        await refresh();
        check(elements.restart.textContent === 'Restart monitoring', 'watch-only actions must name monitoring');
        let sent = 0;
        fetch = async (url, options) => {
          if (url === '/restart') { sent++; return {ok:true}; }
          return {ok:true, json:async () => state};
        };
        const first = command('restart');
        const second = command('restart');
        await Promise.all([first, second]);
        check(sent === 1, 'pending commands must not be duplicated');
        fetch = async () => { throw new Error('offline'); };
        await refresh();
        check(elements.status.innerHTML === '' && elements.actions.hidden, 'connection failure must clear stale controls');
        check(elements.err.textContent === 'Cannot reach Hearth.', 'connection failure must be visible');
        """)
    }

    private func run(_ scenario: String) throws {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, error in
            Issue.record("JavaScript error: \(error?.toString() ?? "unknown")")
        }
        context.evaluateScript(Self.fixture)
        let html = ControlStatusPage.html
        let start = try #require(html.range(of: "<script>")?.upperBound)
        let end = try #require(html.range(of: "</script>")?.lowerBound)
        context.evaluateScript(String(html[start..<end]))
        context.evaluateScript("var result = ''; (async () => { \(scenario); result = 'passed'; })().catch(e => { result = String(e); });")
        for _ in 0..<100 where context.objectForKeyedSubscript("result")?.toString() == "" {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        #expect(context.objectForKeyedSubscript("result")?.toString() == "passed")
    }

    private static let fixture = """
    const elements = {};
    for (const id of ['token','access','access-label','forget','err','status','actions','activity','start','stop','restart','connect']) {
      elements[id] = {value:'',innerHTML:'',textContent:'',hidden:true,open:true,disabled:false,listeners:{},
        addEventListener(name, fn) { this.listeners[name] = fn; }};
    }
    const document = {getElementById: id => elements[id],
      querySelectorAll: () => [elements.start,elements.stop,elements.restart]};
    const storage = {};
    const sessionStorage = {getItem:k => storage[k] || null, setItem:(k,v) => storage[k] = v,
      removeItem:k => delete storage[k]};
    const state = {phase:'healthy',mode:'managed',models:['<model>'],restartCount:0,credentialAccess:'control'};
    let fetch = async () => ({ok:true,json:async () => state});
    const confirm = () => true;
    const setTimeout = () => {};
    const setInterval = () => {};
    function check(condition, message) { if (!condition) throw new Error(message); }
    """
}
