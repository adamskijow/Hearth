<!-- SPDX-License-Identifier: MIT -->
# Inference evidence and recovery

September 7, 2026. These changes are in source after v1.5.1; they are not a new
binary release.

## Adversarial findings and corrections

The first patch separated proxy deferral from shallow busy-timeout recovery and
kept withheld inference failures visible. An independent adversarial review then
reproduced four remaining defects in isolated tests against that implementation.

| Scenario | Reproduced behavior | Correction |
| --- | --- | --- |
| Manual restart during a down notification | Resumed old effects kill the new child | Check control generation across effect awaits; teardown precedes down notifications |
| Repeated inference failure followed by respawn | First unconfirmed failure on replacement announces recovery | Preserve the incident until a validated inference completion |
| Deep HTTP 503 with every poll deep-due | Shared busy timeout restarts without traffic evidence | Deep queue-full responses defer; only shallow busy uses the busy timeout |
| Attached stop/start inside deep interval | New session skips its first check and retains the old failure time | Reset session evidence and scheduling in both modes |

The review also identified permissive HTTP 200 validation and model catalogs
being mistaken for residency. Automatic probes now require a runner adapter
that reports loaded models: Ollama `/api/ps` or LM Studio's loaded-state list.
MLX and Osaurus catalog membership does not prove residency, so scheduled
inference checks are deferred for those adapters. Their catalogs are not shown
as resident models. Deliberate model tests and client requests remain possible.

A successful Ollama probe must have `done: true` and a positive integer
`eval_count`. OpenAI-style completions require a finished choice and generated
content or positive completion-token usage. Empty, malformed, unfinished, error,
and oversized completion bodies cannot clear an incident. Validation decodes at
most 64 KiB and does not retain response text in evidence.

The second review also caught recent verification surviving an observed process
exit. Death, teardown, and replacement now invalidate current verification while
preserving historical timestamps. Stop/start begins a fresh evidence session. Attached mode cannot detect an
external replacement that occurs entirely between observations.

## Additive status contract

Lifecycle `phase` retains its existing meaning. `/status` adds these objects:

| Field | Meaning |
| --- | --- |
| `api` | `status`: unchecked, responding, busy, or unavailable; `checkedAt` is the shallow observation time |
| `inference` | Configured `model`, `lastResult`, `lastCheckedAt`, `lastSuccessAt`, `lastFailureAt`, `validUntil`, `currentProcess`, `incidentOpen`, `activity`, and optional `deferredReason` |
| `inferenceVerified` | Successful evidence from the current process, no unresolved incident, and still within the configured inference interval, evaluated at response time |
| `recovery` | Managed/attached `ownership`, proxy `traffic` evidence, `trafficVisibility: partial`, `inferenceRestartEligible`, and optional `withheldReason` |

Times are ISO 8601 UTC strings. Missing timestamps mean no such observation.
Completed inference evidence and current activity are independent. Deferring a
check cannot refresh an old success or erase a failure. HTTP 503 does not count
as a completed inference failure or success. A single failed check opens an
incident; two paced failures are still required before automatic recovery is
considered. Shallow success, an unloaded model, and replacement alone cannot
clear it. Recovery notifications wait for valid inference when that incident is
open. A fresh stop/start explicitly begins a new observation session.

The existing summaries remain:

- `healthy`: lifecycle ready with no unresolved inference incident. It does not
  establish recent inference success; use `inferenceVerified` for that.
- `inferenceRecoveryWithheld`: confirmed checks failed and the recovery policy
  withheld action. Attached mode never owns or restarts the runner.
- `inferenceDeferredByProxy`: open connections deferred the check, even if idle.
- `headline` and `inferenceNotice`: shared display text; automate against typed
  fields. The headline says **API responding** without current verification and
  **Inference verified** after a valid completion. Failures take precedence.

The menu, CLI, and browser share this wording. `hearth_healthy` and heartbeat
pulses exclude unresolved inference incidents. Metrics also expose current
verification, incident state, last successful completion, and policy eligibility.
Existing phase-only consumers retain their prior semantics.

## Repeatable checks

```sh
./scripts/test.sh --filter 'EngineTests|InferenceEvidenceTests|ControlRoutingTests|StatusTextTests'
python3 scripts/validate-inference.py
```

Build Hearth before running the Python gate. It launches a temporary headless
Hearth against a fake HTTP/1.1 runner and checks API, CLI, metrics, heartbeat, and
TCP relay behavior. It holds a pooled connection beyond the busy timeout, checks
that no probe or recovery occurs, then checks validated recovery after closure.
All configuration, data, ports, and processes are isolated from normal installs.
The unit regressions use a fake clock and controlled process/HTTP seams.

## Next step: traffic evidence

The TCP relay still counts connections rather than requests. Idle pooling and
stalled requests can suppress checks. One observed connection cannot establish
that all clients use the proxy; direct requests remain invisible. Policy
eligibility is not a guarantee that recovery will preserve every client request.

Before expanding the relay, compare runner-native activity evidence with a
bounded HTTP implementation. Test framing, keep-alive reuse, streaming, silent
prefill, cancellation, malformed responses, and client bypass. Preserve the
conservative fallback for unsupported traffic. Then complete a clean setup path
and the controlled local workload milestones in [the product plan](product-plan.md).
No recruitment or outreach is required.
