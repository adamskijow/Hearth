// SPDX-License-Identifier: MIT

import Foundation

/// The HTML served at the control endpoint's `GET /`, so a phone browser can show
/// status with no app. The page itself is an unauthenticated shell that leaks
/// nothing; the token is entered by the user, kept in the browser's localStorage,
/// and sent only on the page's own authenticated `fetch('/status')`. The secret
/// never goes in the URL or the server logs.
public enum ControlStatusPage {
    public static let html = #"""
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Hearth</title>
    <style>
      body { font-family: -apple-system, system-ui, sans-serif; background:#14100c; color:#eee; margin:0; padding:24px; max-width:560px; }
      h1 { font-weight:600; margin:0 0 4px; }
      p.sub { color:#a89; margin:0 0 16px; font-size:14px; }
      .row { display:flex; justify-content:space-between; padding:10px 0; border-bottom:1px solid #2a2420; }
      .k { color:#b89; } .v { font-variant-numeric:tabular-nums; text-align:right; }
      input { width:100%; padding:11px; background:#221c18; border:1px solid #3a322c; color:#eee; border-radius:8px; box-sizing:border-box; font-size:16px; }
      .actions { display:grid; grid-template-columns:repeat(3, 1fr); gap:10px; margin:16px 0; }
      button { padding:11px 8px; border:1px solid #594b40; border-radius:8px; background:#30261f; color:#eee; font-size:15px; }
      button.primary { background:#8a3f18; border-color:#b25b2a; } button:disabled { opacity:.4; }
      button.link { border:0; background:transparent; color:#b89; padding:8px 0; text-align:left; }
      h2 { font-size:16px; font-weight:600; margin:22px 0 6px; }
      .event { color:#c9bdb4; font-size:13px; padding:7px 0; border-bottom:1px solid #2a2420; overflow-wrap:anywhere; }
      .phase-healthy { color:#7ec699; } .phase-down, .phase-failing { color:#e06c6c; } .phase-restarting, .phase-starting { color:#e0a24c; } .phase-stopped { color:#999; }
      #err { color:#e06c6c; font-size:14px; min-height:18px; }
    </style></head>
    <body>
      <h1>&#128293; Hearth</h1>
      <p class="sub">Paste your control token. It stays in this browser only.</p>
      <input id="token" type="password" placeholder="bearer token" autocomplete="off">
      <button id="forget" class="link" type="button">Forget token on this device</button>
      <p id="err"></p>
      <div id="status"></div>
      <div id="actions" class="actions" hidden>
        <button id="start" type="button">Start</button>
        <button id="stop" type="button">Stop</button>
        <button id="restart" class="primary" type="button">Restart</button>
      </div>
      <div id="activity"></div>
    <script>
      const tok = document.getElementById('token');
      tok.value = localStorage.getItem('hearthToken') || '';
      tok.addEventListener('input', () => localStorage.setItem('hearthToken', tok.value));
      function clearPrivate() {
        document.getElementById('status').innerHTML = '';
        document.getElementById('activity').innerHTML = '';
        document.getElementById('actions').hidden = true;
      }
      document.getElementById('forget').addEventListener('click', () => {
        localStorage.removeItem('hearthToken'); tok.value = '';
        clearPrivate();
      });
      function esc(s) { return String(s).replace(/[&<>"']/g, function(c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
      function row(k, v, cls) { return '<div class="row"><span class="k">' + esc(k) + '</span><span class="v ' + esc(cls || '') + '">' + esc(v) + '</span></div>'; }
      function dur(s) { if (s < 60) return Math.round(s) + 's'; const h = Math.floor(s/3600), m = Math.floor(s%3600/60); return h ? (h + 'h ' + m + 'm') : (m + 'm'); }
      async function refresh() {
        const t = tok.value.trim();
        if (!t) { clearPrivate(); return; }
        try {
          const r = await fetch('/status', { headers: { 'Authorization': 'Bearer ' + t } });
          if (!r.ok) { clearPrivate(); document.getElementById('err').textContent = r.status === 401 ? 'Wrong token.' : ('Error ' + r.status); return; }
          document.getElementById('err').textContent = '';
          const s = await r.json();
          let h = row('phase', s.busy ? s.phase + ' (busy)' : s.phase, 'phase-' + s.phase);
          if (s.uptimeSeconds != null) h += row('uptime', dur(s.uptimeSeconds));
          h += row('restarts', s.restartCount);
          if (s.lastDownCategory) h += row('last failure', s.lastDownCategory);
          if (s.lastRestartReason) h += row('last detail', s.lastRestartReason);
          if (s.models && s.models.length) h += row('models', s.models.join(', '));
          if (s.oversizedModels && s.oversizedModels.length) h += row('model warning', s.oversizedModels.join(', ') + ' may be too large');
          if (s.tokensPerSecond != null) h += row('throughput', s.tokensPerSecond + ' tok/s');
          if (s.memoryUsedPercent != null) h += row('memory', s.memoryUsedPercent + '%');
          if (s.thermal) h += row('thermal', s.thermal);
          if (s.deepProbeConfigured) h += row('deep probe', 'on');
          if (s.credentialAccess === 'statusOnly') h += row('access', 'status only');
          document.getElementById('status').innerHTML = h;
          const canControl = s.credentialAccess !== 'statusOnly';
          document.getElementById('actions').hidden = !canControl;
          document.getElementById('start').disabled = s.phase !== 'stopped';
          document.getElementById('stop').disabled = s.phase === 'stopped';
          document.getElementById('restart').disabled = s.phase === 'stopped';
          let activity = '';
          if (s.recentEvents && s.recentEvents.length) {
            activity = '<h2>Recent activity</h2>' + s.recentEvents.slice().reverse().map(e => '<div class="event">' + esc(e) + '</div>').join('');
          }
          document.getElementById('activity').innerHTML = activity;
        } catch (e) { document.getElementById('err').textContent = 'Cannot reach Hearth.'; }
      }
      async function command(name) {
        const t = tok.value.trim();
        if (!t) return;
        if ((name === 'stop' || name === 'restart') && !confirm(name === 'stop' ? 'Stop the runner?' : 'Restart the runner now?')) return;
        const buttons = document.querySelectorAll('.actions button');
        buttons.forEach(b => b.disabled = true);
        document.getElementById('err').textContent = name.charAt(0).toUpperCase() + name.slice(1) + ' requested\u2026';
        try {
          const r = await fetch('/' + name, { method:'POST', headers:{ 'Authorization':'Bearer ' + t } });
          if (!r.ok) throw new Error(r.status === 401 ? 'Wrong token.' : 'Error ' + r.status);
          document.getElementById('err').textContent = '';
          setTimeout(refresh, 250);
        } catch (e) { document.getElementById('err').textContent = e.message || 'Control request failed.'; }
      }
      ['start','stop','restart'].forEach(name => document.getElementById(name).addEventListener('click', () => command(name)));
      setInterval(refresh, 3000); refresh();
    </script>
    </body></html>
    """#
}
