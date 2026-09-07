<!-- SPDX-License-Identifier: MIT -->
# Observability

Authenticated `/status` and `/metrics` report:

- supervisor phase, runner kind, busy state, and last failure category;
- restarts, uptime, deep-probe state, and resident-model count;
- system memory, runner RSS, and thermal state;
- generation throughput when the metrics proxy carries client traffic.

Metrics use bounded labels and exclude prompts, model output, paths, stderr, and
model names. The [monitoring guide](../deploy/monitoring.md) includes Prometheus,
Grafana, and Uptime Kuma examples. Stable fields and metric names are listed in
[Stability](stability.md).

## Limits

`hearth_tokens_per_second` reflects runner-reported timing from proxied responses.
Traffic sent directly to the runner is absent. Latency distributions,
time-to-first-token, and queue depth await reliable runner data.

Ollama's `/api/ps` reports resident models. Some OpenAI-compatible `/v1/models`
endpoints list available models instead, so those values do not prove GPU
residency even where a current UI or metric uses a resident-model label.

Out-of-memory classification remains heuristic. See [Known
limitations](limitations.md) and the [validation
report](../VALIDATION-REPORT.md#exit-classification-out-of-memory-vs-crash).
