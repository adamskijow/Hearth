<!-- SPDX-License-Identifier: MIT -->
# Remote control and status

Enable `controlEnabled` and configure a token to serve Hearth's HTTP endpoint.
Keep it on localhost or a private network.

```sh
curl -H "Authorization: Bearer $TOKEN" http://HOST:11435/status
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/restart
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/stop
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/start
```

Full-control tokens authorize every route. Named `controlStatusTokens` authorize
`GET /status` and `GET /metrics`; process commands return HTTP 403. Give each
dashboard or status client its own named status token. The
`credentialAccess` status field reports the granted scope.

`GET /healthz` is unauthenticated and reports Hearth liveness. `/status` returns
JSON; `/metrics` returns Prometheus text. Their stable fields are listed in
[Stability](stability.md), with dashboards in the [monitoring
guide](../deploy/monitoring.md).

The server rejects missing tokens, rate-limits repeated failures by peer, caps
simultaneous clients, and hardens browser responses against framing, caching,
content sniffing, and cross-origin reads.

## Browser status page

Open `http://HOST:11435/` and paste a token. The page keeps it in the current tab,
uses bearer headers for requests, and forgets it when the tab closes. Status-only
tokens hide Start, Stop, and Restart. Use the page over a VPN or HTTPS proxy.

When Hearth detects Tailscale, the menu shows the phone URL. Setting
`"controlHost": "tailscale"` resolves the current tailnet IPv4 and falls back to
loopback. IPv6 config values use the bare address; clients use brackets in URLs,
such as `http://[fd7a::1]:11435/status`.

## Throughput and heartbeat

The optional metrics proxy records runner-reported token counts and timing from
traffic sent through `metricsProxyPort`. It exposes
`hearth_tokens_per_second`, `hearth_generation_tokens_total`, and
`hearth_generation_requests_total`.

`heartbeatURL` provides an outbound dead-man's switch. Hearth calls it while the
runner is healthy, so a stopped pulse covers runner, Hearth, Mac, and network
failure without inbound access.

## CLI

```text
hearth setup               Detect runner, install login agent, wait for readiness
hearth status [--json]     Health, uptime, restarts, metrics, and models
hearth logs -n 100         Tail the runner log
hearth logs -f             Follow the runner log
hearth events              Read Hearth's event history
hearth events --stats      Summarize incidents and recovery time
hearth metrics             Read retained memory and thermal history
hearth doctor              Check the user config and environment
hearth doctor-daemon       Check /etc/hearth/config.json
hearth mode managed        Give Hearth runner ownership
hearth mode attached       Watch an externally owned runner
hearth wait-ready [-t S]   Wait for runner readiness
hearth install-agent       Install the per-user login agent
hearth uninstall-agent     Remove the login agent
```

`hearth status` queries the control endpoint when enabled and falls back to local
process and port checks. Commands return `0` on success, `1` on operational
failure, and `2` for invalid usage or rejected configuration.

`events.log` records Hearth decisions and survives restarts. The runner log holds
runner stdout and stderr. The menu's **History** window groups incidents and
plots retained memory with restart markers.

Named control tokens add the caller name to start, stop, and restart events.
`hearth doctor` validates token scope, ports, paths, permissions, and manager
conflicts. `hearth mode` edits the config; reload Hearth to apply it.
