<!-- SPDX-License-Identifier: MIT -->
# Remote control and local status

With `controlEnabled` and a `controlToken` set, Hearth runs a small HTTP control
endpoint so a phone can check status and start, stop, or restart the runner, not
just receive notifications. Every request must carry the token as a bearer header.

```
# status
curl -H "Authorization: Bearer $TOKEN" http://HOST:11435/status

# control
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/restart
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/stop
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/start
```

`/status` returns a compact JSON document with the phase, resident models, uptime,
restart count, last restart reason, and the system metrics (thermal state, memory
used percent, runner resident bytes). `/metrics` returns the same data as a
Prometheus text exposition (also behind the token), so you can scrape Hearth into
Grafana or Uptime Kuma; and the unauthenticated `/healthz` returns `200` when Hearth
is up, for an uptime monitor. Ready-made Prometheus, Grafana, and Uptime Kuma recipes
(including a dashboard) are in [deploy/monitoring.md](../deploy/monitoring.md). The
control endpoint is a control surface, not a public API: bind it to localhost or a
private interface (a Tailscale address is ideal) and keep it behind a VPN. It refuses
to start without a token, and rejects any request whose bearer token does not match.

Opening the control URL in a browser (`http://HOST:11435/`) serves a small status
page for phones: paste your token once (it is stored in that browser only, never in
the URL) and it polls `/status` and shows the phase, uptime, and metrics. The page
itself is unauthenticated but reveals nothing; the status fetch it makes carries the
token.

When Hearth detects a Tailscale address on the machine (an interface in the
100.64.0.0/10 range), the menubar shows a "Phone access" line with the full control
URL to use from your phone. Hearth only reads the interface list; it does not
configure Tailscale.

## Local status and logs

From the same machine, terminal subcommands give a quick read without the menubar or
a curl invocation:

```
hearth setup               # turnkey: detect runner, install login agent, wait for ready
hearth status [--json]     # phase, uptime, restarts, metrics, resident models (--json for agents)
hearth logs -n 100         # last 100 lines of the runner log
hearth logs -f             # follow the runner log
hearth events              # Hearth's own event history (down, restart, recovered)
hearth metrics             # memory and thermal history over the retained window
hearth doctor              # check the config and environment for problems
hearth wait-ready [-t S]   # block until the runner answers, then exit 0 (1 on timeout)
hearth install-agent       # install a login agent that keeps Hearth running (no sudo)
hearth uninstall-agent     # remove that login agent
```

`hearth status` reads the config (at `HEARTH_CONFIG` or the standard location) and
queries the control endpoint when it is enabled, printing the full picture. With the
control endpoint off it falls back to a reduced report: whether a supervised runner
is recorded and alive, and whether anything is serving on the runner's port.

Hearth records its own decisions (became healthy, down with the cause, restart
scheduled, recovered, crash loop) to a small line-capped `events.log` next to the
runner log. Unlike the in-memory recent-activity list, this survives a restart, so
`hearth events`, the menu's Recent activity, and the tail shown by `hearth status`
all answer "why did it restart last night." The runner log (`hearth logs`) is the
runner's own stdout and stderr; the event log is Hearth's view of it.

`hearth doctor` is a preflight check. It validates the config (port ranges, an
unknown runner or mode, a control endpoint with no token, a control port that
collides with the runner port, backoff timings that cannot grow) and the environment
(the runner binary exists and is executable, the runner port is free for a managed
runner or already serving for an attached one, the log directory is writable), then
prints each result and exits non-zero if anything is an error.
