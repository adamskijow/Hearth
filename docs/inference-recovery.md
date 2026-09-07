<!-- SPDX-License-Identifier: MIT -->
# Inference recovery: first implementation

September 7, 2026. These changes are in source after v1.5.1; they are not a new
binary release.

## Reproduced behavior

| Scenario | Before | First correction |
| --- | --- | --- |
| Repeated inference failures, no observed client traffic | Advisory fires, headline remains Healthy | Persistent failure headline, `healthy: false`, no forced restart |
| Shallow success or unloaded model after that incident | Healthy headline hides unresolved inference failure | Warning persists until successful inference or a fresh supervision session |
| Open proxy connection with 5-second polling and 60-second deep cadence | Intermediate polls reset the busy timer; checks remain skipped | Explicit proxy deferral, separate from runner busy |
| Open proxy connection with 61-second polling and 60-second deep cadence | Busy timeout initiates recovery despite no runner-reported failure | No busy-timeout recovery from a connection count |
| Client connects while a failing inference POST is pending | Preflight connection count can authorize recovery using stale evidence | Connection count checked again when the POST completes |
| Stop/start while a failing POST is pending | Result can update inference bookkeeping for the old session | Old-session result discarded |

The first two regression tests were run against the previous implementation.
They failed with three misleading-headline assertions and an unexpected
termination in the 61-second polling case. The corrected tests pass. The fake
clock covers 750 seconds without sleeping or touching a real runner.

## Current status contract

The lifecycle `phase` remains unchanged. New `/status` fields are additive:

- `healthy`: lifecycle ready with no unresolved inference incident whose recovery
  is withheld. It does not establish recent inference success.
- `inferenceRecoveryWithheld`: confirmed inference checks failed and recovery
  was withheld because client activity could not be ruled out.
- `inferenceDeferredByProxy`: an open proxy connection deferred the check. The
  connection may be idle; this is separate from a runner HTTP 503 response.
- `headline` and optional `inferenceNotice`: display text used by the CLI and
  browser. Clients should automate against typed fields.

The menu uses the same headline and notice. `hearth_healthy` and heartbeat pulses
exclude unresolved withheld-recovery incidents. Two new gauges expose the
inference flags. Existing phase-based consumers retain their prior semantics.

## Repeatable local check

Build Hearth, then run:

```sh
python3 scripts/validate-inference.py
```

The gate launches one temporary headless Hearth in attached mode against a fake
HTTP/1.1 runner. It checks real API, CLI, metrics, heartbeat, and TCP relay
behavior. After a complete response it keeps a pooled client connection open
beyond the busy timeout, checks that no inference probe or recovery occurs,
then verifies that successful inference clears the incident after closure.
All configuration, data, ports, and processes are isolated from normal installs.

## Next state-model change

The full separation proposed in the product plan remains to be implemented:

| Surface | Proposed evidence |
| --- | --- |
| API | Responding, unavailable, or unchecked, with the observation time |
| Inference | Model, last completed result, last success/failure times, and the current check or deferral reason |
| Recovery | Process owner, supported failure types, and the reason recovery is available or withheld |

Store the last inference result separately from the current check activity. A
deferred check must not overwrite an unresolved failure or make an old success
look fresh. Keep the fields introduced here as compatible summaries when adding
that structured evidence.

The TCP relay still counts connections rather than requests. This patch prevents
connections from becoming false busy-timeout failures; it does not solve idle
pooling, stalled-request diagnosis, or direct-client bypass. One observed
connection cannot establish complete traffic visibility. Protocol-aware or
runner-native activity evidence needs its own tests before changing that policy.
