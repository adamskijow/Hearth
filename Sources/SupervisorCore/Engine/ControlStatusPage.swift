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
      .phase-healthy { color:#7ec699; } .phase-down, .phase-failing { color:#e06c6c; } .phase-restarting, .phase-starting { color:#e0a24c; } .phase-stopped { color:#999; }
      #err { color:#e06c6c; font-size:14px; min-height:18px; }
    </style></head>
    <body>
      <h1>&#128293; Hearth</h1>
      <p class="sub">Paste your control token. It stays in this browser only.</p>
      <input id="token" type="password" placeholder="bearer token" autocomplete="off">
      <p id="err"></p>
      <div id="status"></div>
    <script>
      const tok = document.getElementById('token');
      tok.value = localStorage.getItem('hearthToken') || '';
      tok.addEventListener('input', () => localStorage.setItem('hearthToken', tok.value));
      function esc(s) { return String(s).replace(/[&<>"']/g, function(c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
      function row(k, v, cls) { return '<div class="row"><span class="k">' + esc(k) + '</span><span class="v ' + esc(cls || '') + '">' + esc(v) + '</span></div>'; }
      function dur(s) { if (s < 60) return Math.round(s) + 's'; const h = Math.floor(s/3600), m = Math.floor(s%3600/60); return h ? (h + 'h ' + m + 'm') : (m + 'm'); }
      async function refresh() {
        const t = tok.value.trim();
        if (!t) { document.getElementById('status').innerHTML = ''; return; }
        try {
          const r = await fetch('/status', { headers: { 'Authorization': 'Bearer ' + t } });
          if (!r.ok) { document.getElementById('err').textContent = r.status === 401 ? 'Wrong token.' : ('Error ' + r.status); return; }
          document.getElementById('err').textContent = '';
          const s = await r.json();
          let h = row('phase', s.phase, 'phase-' + s.phase);
          if (s.uptimeSeconds != null) h += row('uptime', dur(s.uptimeSeconds));
          h += row('restarts', s.restartCount);
          if (s.models && s.models.length) h += row('models', s.models.join(', '));
          if (s.memoryUsedPercent != null) h += row('memory', s.memoryUsedPercent + '%');
          if (s.thermal) h += row('thermal', s.thermal);
          document.getElementById('status').innerHTML = h;
        } catch (e) { document.getElementById('err').textContent = 'Cannot reach Hearth.'; }
      }
      setInterval(refresh, 3000); refresh();
    </script>
    </body></html>
    """#
}
