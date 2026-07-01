<!-- SPDX-License-Identifier: MIT -->
# Observability roadmap

Hearth's current metrics describe supervision: whether Hearth is up, whether the
runner is healthy, restart counts, system memory, runner RSS, thermal state, and
resident model count. They are enough to answer "is my local runner serving," but
not yet enough to profile inference performance.

## Near-term additions

- **Runner type and down reason:** add low-cardinality labels or separate gauges
  for runner kind, current phase, and last down reason. Avoid labels that include
  model names, prompts, paths, or arbitrary stderr.
- **Restart reason:** expose the last restart category in a bounded way, such as
  crash, wedged, maintenance, manual, or binary-upgrade.
- **Deep-probe status:** report whether a deep probe is configured and when it
  last failed, without recording prompt or model output.

## Throughput

Tokens per second is useful, but Hearth should not become an inference proxy just
to measure it. Prefer these sources, in order:

1. Runner-provided metrics or APIs, if Ollama exposes stable counters.
2. Structured runner log lines, if they are stable enough to parse without
   creating false confidence.
3. A clearly opt-in synthetic probe, only if it can stay cheap and avoid changing
   the user's model residency policy.

If none of those sources are stable, keep tokens/sec on the roadmap rather than
guessing.

## Runner-specific model state

Ollama's `/api/ps` reports resident models, which is what Hearth shows today. Some
OpenAI-compatible runners only expose `/v1/models`, which can mean "known models"
rather than "loaded in GPU memory." Until a runner exposes true residency, Hearth
should label that data honestly in docs and UI.

## OOM verification

Out-of-memory classification is currently heuristic. To verify it:

1. Run Hearth on constrained Apple Silicon hardware.
2. Trigger a real Metal or unified-memory failure with an oversized model or
   context.
3. Capture the runner stderr lines.
4. Add the lines as fixtures and assert the classifier returns out-of-memory.

Healthy Ollama logs should remain negative fixtures so common words around memory
do not become false positives.
