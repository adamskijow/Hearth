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

`/status` returns a compact JSON document. The exact keys, for anything that
parses it: `phase` (string), `busy` (bool: the runner answered 503, a full
queue, on the last probe), `models` (array of strings), `uptimeSeconds`
(number or absent), `restartCount` (number), `consecutiveFailures` (number),
`lastRestartReason` (string or absent), `lastDownCategory` (string or absent;
one of `wedged`, `crash`, `oom`, `signal`, `clean-exit`, `unknown`),
`deepProbeConfigured` (bool), `thermal` (string or absent),
`memoryUsedPercent` (number or absent), and `runnerResidentBytes` (number or
absent). `/metrics` returns the same data as a
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

With the opt-in metrics proxy enabled (`metricsProxyEnabled`; point your apps
at `metricsProxyPort` instead of the runner port), `/metrics` also carries
request-level throughput: `hearth_tokens_per_second` (the most recent
generation with timing), `hearth_generation_tokens_total`, and
`hearth_generation_requests_total`. The numbers are what the runner itself
reports in its responses; traffic that goes straight to the runner is not
counted.

For a dashboard you already run, Hearth can also push instead of being polled:
set `heartbeatURL` to an Uptime Kuma push monitor or a healthchecks.io check
URL and Hearth GETs it on an interval while the runner is healthy. The pulse
stopping is the signal, so Hearth being dead, the Mac being off, and the
runner being wedged all read as down in the monitor, with no inbound access to
the Mac needed.

`controlHost` can be an IPv6 address (`::1`, or a Tailscale `fd7a:...` address):
set the bare address in the config and Hearth brackets it wherever a URL is
built, including `hearth status` and the advertised phone-access URL. In your
own curl invocations, bracket it yourself (`http://[fd7a::...]:11435/status`).

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
hearth doctor-daemon       # check /etc/hearth/config.json for the root daemon
hearth mode managed        # Hearth starts and restarts the runner
hearth mode attached       # Hearth watches a runner started by something else
hearth wait-ready [-t S]   # block until the runner answers, then exit 0 (1 on timeout)
hearth install-agent       # install a login agent that keeps Hearth running (no sudo)
hearth uninstall-agent     # remove that login agent
```

`hearth status` reads the config (at `HEARTH_CONFIG` or the standard location) and
queries the control endpoint when it is enabled, printing the full picture. With the
control endpoint off it falls back to a reduced report: whether a supervised runner
is recorded and alive, and whether anything is serving on the runner's port.

Exit codes, for scripts: subcommands exit `0` on success and non-zero on failure
(`hearth doctor` exits non-zero when it finds an error; `hearth wait-ready` exits
`1` on timeout). An unknown subcommand (`hearth statuss`) prints an error to
stderr and exits `2` rather than launching the app.

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
prints each result and exits non-zero if anything is an error. `hearth doctor-daemon`
does the same check against `/etc/hearth/config.json` for the root LaunchDaemon and
should be run with `sudo`.

`hearth mode managed|attached` edits the config explicitly. Switching to attached
mode refuses by default unless a compatible runner is already serving at the
configured host and port; use `--force` only when you plan to start that runner
yourself later. Add `--daemon` with sudo to edit the root daemon config. It only
edits the config: reload a running Hearth for the change to take effect (Reload
Config in the menu or `killall -HUP Hearth`; for the root daemon,
`sudo launchctl kickstart -k system/com.hearth.daemon`).
