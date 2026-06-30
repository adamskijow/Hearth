<!-- SPDX-License-Identifier: MIT -->
# Monitoring Hearth

Hearth's control endpoint exposes three things a monitoring stack can use, all on
`controlPort` (default `11435`):

- `GET /metrics` (Prometheus text, requires the bearer token)
- `GET /status` (JSON, requires the bearer token)
- `GET /healthz` (unauthenticated, returns `200` when Hearth is up)

Enable the control endpoint first (`controlEnabled` with a `controlToken`), and
bind it to a private interface (localhost or a Tailscale address), never the open
internet. See the README's "Security and exposing the runner".

## Prometheus

Scrape `/metrics` with the token:

```yaml
scrape_configs:
  - job_name: hearth
    metrics_path: /metrics
    scheme: http
    authorization:
      type: Bearer
      credentials: "YOUR_CONTROL_TOKEN"
    static_configs:
      - targets: ["YOUR_MAC_HOST:11435"]
```

The exposed series (all `gauge` unless noted):

| Metric | Meaning |
|--------|---------|
| `hearth_up` | Hearth is up and answering (1). |
| `hearth_healthy` | The runner is healthy (1) or not (0). |
| `hearth_phase{phase=...}` | Current supervisor phase; the active one is 1. |
| `hearth_restarts_total` (counter) | Restarts this session. |
| `hearth_consecutive_failures` | Consecutive failed readiness probes. |
| `hearth_uptime_seconds` | Seconds the runner has been continuously healthy. |
| `hearth_resident_models` | Models the runner currently holds resident. |
| `hearth_memory_used_percent` | System memory in use, percent. |
| `hearth_runner_resident_bytes` | Resident memory of the runner process, bytes. |
| `hearth_thermal{state=...}` | Thermal state; the active one is 1. |

A useful alert is the wedge itself, healthy flips to 0 while the process is still
alive:

```yaml
groups:
  - name: hearth
    rules:
      - alert: HearthRunnerUnhealthy
        expr: hearth_up == 1 and hearth_healthy == 0
        for: 1m
        annotations:
          summary: "Local LLM runner is up but not answering (wedged or restarting)"
      - alert: HearthMemoryPressure
        expr: hearth_memory_used_percent >= 90
        for: 2m
        annotations:
          summary: "System memory high; the runner is at risk of being killed"
```

## Grafana

Import [`grafana-dashboard.json`](grafana-dashboard.json) (Dashboards, New, Import)
and pick your Prometheus datasource when prompted. It has health, phase, uptime,
restarts, system and runner memory, consecutive failures, thermal state, and
resident models.

## Uptime Kuma

Two monitors give you liveness and readiness:

1. **Hearth liveness**, type `HTTP(s)`, URL `http://YOUR_MAC_HOST:11435/healthz`,
   accepted status `200`. No auth needed. This catches Hearth itself being down.
2. **Runner readiness**, type `HTTP(s) - Keyword`, URL
   `http://YOUR_MAC_HOST:11435/status`, keyword `healthy`, with a request header
   `Authorization: Bearer YOUR_CONTROL_TOKEN`. The keyword is present only when the
   runner is actually answering, so a wedge (phase `down`, `restarting`, or
   `failing`) trips the monitor even though the process is alive.

Set the check interval to 60 seconds for both.
