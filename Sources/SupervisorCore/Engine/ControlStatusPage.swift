// SPDX-License-Identifier: MIT

import Foundation

/// The HTML served at the control endpoint's `GET /`, so a phone browser can show
/// status with no app. The page itself is an unauthenticated shell that leaks
/// nothing; the token is entered by the user, kept in the browser's sessionStorage,
/// and sent only on the page's own authenticated `fetch('/status')`. The secret
/// never goes in the URL or the server logs, and closing the browser tab forgets
/// it instead of leaving a full-control credential behind indefinitely.
public enum ControlStatusPage {
    public static let html = #"""
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Hearth</title>
    <style>
      :root { color-scheme:light dark; --line:#ddd; --muted:#666; --field:#fff; --healthy:#24733d; --failure:#b42318; --waiting:#805900; }
      @media (prefers-color-scheme:dark) { :root { --line:#444; --muted:#aaa; --field:#242424; --healthy:#81c995; --failure:#f28b82; --waiting:#fdd663; } }
      [hidden] { display:none !important; }
      body { font:16px/1.45 -apple-system, system-ui, sans-serif; background:Canvas; color:CanvasText; margin:24px auto; padding:0 20px; max-width:560px; }
      h1 { font-weight:600; margin:0 0 4px; }
      p.sub { color:var(--muted); margin:8px 0 16px; font-size:14px; }
      .row { display:flex; justify-content:space-between; gap:16px; padding:10px 0; border-bottom:1px solid var(--line); }
      .k { color:var(--muted); flex-shrink:0; } .v { font-variant-numeric:tabular-nums; text-align:right; overflow-wrap:anywhere; min-width:0; }
      #status .row:first-child { font-size:18px; font-weight:600; }
      label { display:block; margin:12px 0 6px; }
      input { width:100%; padding:10px; background:var(--field); border:1px solid var(--line); color:CanvasText; border-radius:6px; box-sizing:border-box; font-size:16px; }
      .actions { display:grid; grid-template-columns:repeat(3, 1fr); gap:10px; margin:16px 0; }
      button { padding:10px 8px; border:1px solid var(--line); border-radius:6px; background:var(--field); color:CanvasText; font-size:15px; cursor:pointer; }
      button:disabled { opacity:.4; cursor:default; }
      button.link { border:0; background:transparent; color:var(--muted); padding:8px 0; }
      form button { margin-top:12px; margin-right:12px; }
      details { margin-top:24px; } summary { cursor:pointer; color:var(--muted); }
      h2 { font-size:16px; font-weight:600; margin:22px 0 6px; }
      .event { color:var(--muted); font-size:13px; padding:7px 0; border-bottom:1px solid var(--line); overflow-wrap:anywhere; }
      .phase-healthy { color:var(--healthy); } .phase-down, .phase-failing { color:var(--failure); } .phase-restarting, .phase-starting { color:var(--waiting); } .phase-stopped { color:var(--muted); }
      #err { color:var(--failure); font-size:14px; } #err:empty { display:none; }
    </style></head>
    <body>
      <h1>Hearth</h1>
      <p id="err" role="status"></p>
      <div id="status" aria-live="polite"></div>
      <div id="actions" class="actions" hidden>
        <button id="start" type="button">Start</button>
        <button id="stop" type="button">Stop</button>
        <button id="restart" type="button">Restart</button>
      </div>
      <div id="activity"></div>
      <details id="access" open>
        <summary id="access-label">Connect</summary>
        <p class="sub">Use Tailscale, a VPN, or HTTPS. Your token stays in this tab only.</p>
        <form id="connect">
          <label for="token">Access token</label>
          <input id="token" type="password" autocomplete="off">
          <button type="submit">Connect</button>
          <button id="forget" class="link" type="button">Forget token</button>
        </form>
      </details>
    <script>
      const tok = document.getElementById('token');
      const access = document.getElementById('access');
      let connected = false, refreshID = 0, commandPending = false, managed = true;
      tok.value = sessionStorage.getItem('hearthToken') || '';
      tok.addEventListener('input', () => {
        sessionStorage.setItem('hearthToken', tok.value);
        refreshID++; clearPrivate();
        document.getElementById('err').textContent = '';
      });
      function clearPrivate() {
        document.getElementById('status').innerHTML = '';
        document.getElementById('activity').innerHTML = '';
        document.getElementById('actions').hidden = true;
        connected = false;
        access.open = true;
        document.getElementById('access-label').textContent = 'Connect';
      }
      document.getElementById('forget').addEventListener('click', () => {
        sessionStorage.removeItem('hearthToken'); tok.value = '';
        refreshID++; clearPrivate();
        document.getElementById('err').textContent = '';
      });
      function esc(s) { return String(s).replace(/[&<>"']/g, function(c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
      function row(k, v, cls) { return '<div class="row"><span class="k">' + esc(k) + '</span><span class="v ' + esc(cls || '') + '">' + esc(v) + '</span></div>'; }
      function dur(s) { if (s < 60) return Math.round(s) + 's'; const h = Math.floor(s/3600), m = Math.floor(s%3600/60); return h ? (h + 'h ' + m + 'm') : (m + 'm'); }
      async function refresh() {
        const current = ++refreshID;
        const t = tok.value.trim();
        if (!t) { clearPrivate(); return; }
        try {
          const r = await fetch('/status', { headers: { 'Authorization': 'Bearer ' + t } });
          if (current !== refreshID || t !== tok.value.trim()) return;
          if (!r.ok) { clearPrivate(); document.getElementById('err').textContent = r.status === 401 ? 'Wrong token.' : (r.status === 429 ? 'Too many failed attempts. Try again in a minute.' : ('Error ' + r.status)); return; }
          document.getElementById('err').textContent = '';
          const s = await r.json();
          if (current !== refreshID || t !== tok.value.trim()) return;
          if (!connected) { access.open = false; connected = true; }
          document.getElementById('access-label').textContent = 'Access token';
          managed = s.mode !== 'attached';
          const color = s.phase === 'healthy' && s.healthy === false ? 'phase-failing' : (s.phase === 'healthy' && s.inferenceDeferredByProxy ? 'phase-starting' : 'phase-' + s.phase);
          let h = row('status', s.headline || (s.busy ? s.phase + ' (busy)' : s.phase), color);
          if (s.inferenceNotice) h += row('inference', s.inferenceNotice);
          if (s.trafficNotice) h += row('clients', s.trafficNotice);
          if (s.uptimeSeconds != null) h += row('uptime', dur(s.uptimeSeconds));
          h += row('restarts', s.restartCount);
          if (s.lastDownCategory) h += row('last failure', s.lastDownCategory);
          if (s.lastRestartReason) h += row('last detail', s.lastRestartReason);
          if (s.models && s.models.length) h += row('models', s.models.join(', '));
          if (s.oversizedModels && s.oversizedModels.length) h += row('model warning', s.oversizedModels.join(', ') + ' may be too large');
          if (s.tokensPerSecond != null) h += row('throughput', s.tokensPerSecond + ' tok/s');
          if (s.memoryUsedPercent != null) h += row('memory', s.memoryUsedPercent + '%');
          if (s.thermal) h += row('thermal', s.thermal);
          if (s.deepProbeConfigured) h += row('model checks', 'on');
          if (s.credentialAccess === 'statusOnly') h += row('access', 'status only');
          document.getElementById('status').innerHTML = h;
          const canControl = s.credentialAccess !== 'statusOnly';
          document.getElementById('actions').hidden = !canControl;
          for (const name of ['start', 'stop', 'restart']) {
            document.getElementById(name).textContent = name.charAt(0).toUpperCase() + name.slice(1) + (managed ? ' server' : ' monitoring');
          }
          document.getElementById('start').disabled = commandPending || s.phase !== 'stopped';
          document.getElementById('stop').disabled = commandPending || s.phase === 'stopped';
          document.getElementById('restart').disabled = commandPending || s.phase === 'stopped';
          let activity = '';
          if (s.recentEvents && s.recentEvents.length) {
            activity = '<h2>Recent activity</h2>' + s.recentEvents.slice().reverse().map(e => '<div class="event">' + esc(e) + '</div>').join('');
          }
          document.getElementById('activity').innerHTML = activity;
        } catch (e) {
          if (current !== refreshID || t !== tok.value.trim()) return;
          clearPrivate();
          document.getElementById('err').textContent = 'Cannot reach Hearth.';
        }
      }
      async function command(name) {
        const t = tok.value.trim();
        if (!t || commandPending) return;
        const target = managed ? 'server' : 'monitoring';
        if ((name === 'stop' || name === 'restart') && !confirm(name === 'stop' ? 'Stop the ' + target + '?' : 'Restart the ' + target + ' now?')) return;
        commandPending = true;
        const buttons = document.querySelectorAll('.actions button');
        buttons.forEach(b => b.disabled = true);
        document.getElementById('err').textContent = name.charAt(0).toUpperCase() + name.slice(1) + ' requested\u2026';
        try {
          const r = await fetch('/' + name, { method:'POST', headers:{ 'Authorization':'Bearer ' + t } });
          if (!r.ok) throw new Error(r.status === 401 ? 'Wrong token.' : 'Error ' + r.status);
          document.getElementById('err').textContent = '';
          setTimeout(refresh, 250);
        } catch (e) { document.getElementById('err').textContent = e.message || 'Control request failed.'; }
        finally { commandPending = false; }
      }
      document.getElementById('connect').addEventListener('submit', e => { e.preventDefault(); refresh(); });
      ['start','stop','restart'].forEach(name => document.getElementById(name).addEventListener('click', () => command(name)));
      setInterval(refresh, 3000); refresh();
    </script>
    </body></html>
    """#
}
