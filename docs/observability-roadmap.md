<!-- SPDX-License-Identifier: MIT -->
# Observability roadmap

Hearth's metrics describe supervision: whether Hearth is up, whether the runner is
healthy, its phase and last failure category, restart counts, busy state,
deep-probe status, system memory, runner RSS, thermal state, and resident model
count. With the optional metrics proxy on, they also carry generation throughput.
They answer "is my local runner serving, and how is it behaving," but still not a
full inference profile.

The Prometheus surface is `/metrics` on the control endpoint; the same data is on
`/status` as JSON. Both avoid labels that include model names, prompts, paths, or
arbitrary stderr.

## Shipped

Most of this document's original near-term list has landed:

- **Phase and last-down reason** as low-cardinality labels: `hearth_phase{phase}`
  and `hearth_last_down{reason}` (the bounded down category, such as crash, wedged,
  or out-of-memory). `/status` also carries `lastRestartReason` and
  `lastDownCategory`.
- **Deep-probe status:** `hearth_deep_probe_configured` and
  `hearth_deep_probe_last_failure_timestamp_seconds`, and `deepProbeConfigured` on
  `/status`. No prompt or model output is recorded, only whether a deep probe is
  configured and when it last failed.
- **Busy state:** `hearth_busy`, so a runner that answers 503 (queue full) is
  distinguishable from a wedge.
- **Throughput:** `hearth_tokens_per_second`, `hearth_generation_tokens_total`, and
  `hearth_generation_requests_total`, with `tokensPerSecond` and
  `generationTokensTotal` on `/status`. This is measured by the optional,
  opt-in metrics proxy, which scans real generation responses for token counts
  rather than issuing synthetic requests, so it does not change the runner's model
  residency. This satisfies the throughput goal below without turning Hearth into
  a required inference proxy: the proxy is off by default and transparent when on.

## Still open

- **Runner-kind label.** The metrics do not yet distinguish runner kinds (Ollama,
  LM Studio, mlx_lm, Osaurus). Add a low-cardinality `runner` label or a per-kind
  gauge, avoiding binary paths.
- **A bounded restart-category metric.** The down cause is exposed as
  `hearth_last_down`, but the restart reason on `/status` is still a free-form
  string. A bounded restart-category gauge (crash, wedged, maintenance, manual,
  binary-upgrade) is not yet a metric.
- **Richer inference profiling.** Tokens/sec is a single scalar. Latency
  distributions, time-to-first-token, and queue depth would need either stable
  runner-provided counters or deeper response parsing, and are deliberately not
  attempted until a source exists that will not create false confidence.

## Runner-specific model state

Ollama's `/api/ps` reports resident models, which is what Hearth shows today. Some
OpenAI-compatible runners only expose `/v1/models`, which can mean "known models"
rather than "loaded in GPU memory." Until a runner exposes true residency, Hearth
labels that data honestly in docs and UI rather than implying residency it cannot
confirm.

## OOM verification

Out-of-memory classification is still heuristic and UNVERIFIED against a real Metal
kill. The verification steps are now automated by `scripts/capture-oom.sh`, which
starts a runner, drives an oversized generation, and checks the captured stderr
against the shipped signatures. What it needs is hardware: the 128 GiB development
Mac cannot induce a Metal OOM, and the live GPU-crash test in
[VALIDATION-REPORT.md](../VALIDATION-REPORT.md#live-gpu-crash-test) produced a
jetsam SIGKILL with no `ggml`/`metal` stderr, a different failure mode. Running the
script on a constrained Apple Silicon Mac would capture the real signature and
close this out. Healthy Ollama logs remain negative fixtures so common words around
memory do not become false positives.
