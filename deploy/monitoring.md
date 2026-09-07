<!-- SPDX-License-Identifier: MIT -->
# Monitoring Hearth

Hearth's `controlPort` (default `11435`) exposes:

- `GET /metrics` (Prometheus text, requires the bearer token)
- `GET /status` (JSON, requires the bearer token)
- `GET /healthz` (unauthenticated, returns `200` when Hearth is up)

Enable `controlEnabled` with a token and bind to localhost or a VPN address.

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
| `hearth_runner_info{runner=...}` | Configured runner kind. |
| `hearth_healthy` | Supervisor phase is healthy (1) or not (0); not proof of successful inference. |
| `hearth_busy` | Last check reported busy through HTTP or proxy-observed connections (1). |
| `hearth_phase{phase=...}` | Current supervisor phase; the active one is 1. |
| `hearth_last_down{reason=...}` | Last failure category. |
| `hearth_last_restart{category=...}` | Last restart category. |
| `hearth_deep_probe_configured` | Inference probe enabled (1). |
| `hearth_deep_probe_last_failure_timestamp_seconds` | Last inference-probe failure. |
| `hearth_restarts_total` (counter) | Restarts this session. |
| `hearth_consecutive_failures` | Consecutive failed readiness probes. |
| `hearth_uptime_seconds` | Seconds the runner has been continuously healthy. |
| `hearth_resident_models` | Model count reported by the adapter; residency semantics depend on the runner. |
| `hearth_memory_used_percent` | System memory in use, percent. |
| `hearth_runner_resident_bytes` | Resident memory of the runner process, bytes. |
| `hearth_thermal{state=...}` | Thermal state; the active one is 1. |
| `hearth_generation_requests_total` (counter) | Generations seen by the metrics proxy. |
| `hearth_generation_tokens_total` (counter) | Generated tokens seen by the proxy. |
| `hearth_tokens_per_second` | Most recent runner-reported throughput. |

A basic alert watches supervisor health. Inference failures can remain advisory
while this phase is healthy; inspect inference alerts and the last-failure
timestamp as well. See [known limitations](../docs/limitations.md).

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
   `http://YOUR_MAC_HOST:11435/status`, keyword `"phase":"healthy"`, with a request
   header `Authorization: Bearer YOUR_CONTROL_TOKEN`. Match the phase field rather
   than the word `healthy`, which may also appear in historical event text. This
   checks the supervisor phase, not successful model generation. If your proxy
   reformats JSON, use a JSON query for `phase` equal to `healthy` instead.

Set the check interval to 60 seconds for both.
