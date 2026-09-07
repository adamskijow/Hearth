<!-- SPDX-License-Identifier: MIT -->
# Known limitations

- A runner restart clears process-level failures. GPU or driver hangs may require
  a Mac reboot. The root daemon offers opt-in, loop-guarded
  [reboot escalation](running-headless.md#recovering-a-wedge-a-restart-cannot).
- Out-of-memory classification uses stderr and exit-status heuristics. Healthy-log
  fixtures guard against false positives, but a real Metal OOM has not been
  captured on the 128 GiB development Mac. `scripts/capture-oom.sh <model>` can
  collect evidence on a constrained Apple silicon Mac.
- An abrupt Hearth `SIGKILL` leaves its managed process group alive until Hearth
  relaunches and sweeps the recorded identity. Normal quit and `SIGTERM` reap it
  immediately.
- The power assertion covers idle sleep. It cannot keep a closed, unplugged laptop
  serving.
- Supervision timers use wall time. Sleep can make a maintenance restart due
  immediately after wake.
- LM Studio supports attached mode. Its CLI starts a background service and exits,
  which cannot provide a managed child process.
- The control endpoint uses bearer tokens and plain HTTP. Keep it on localhost or
  a VPN, or add an HTTPS reverse proxy.
- An inference timeout cannot distinguish a hang from unseen queued work.
  Deep-probe restart requires client traffic through the metrics proxy; otherwise
  Hearth alerts and leaves the runner in place.
- The proxy observes a bounded subset of HTTP/1 request framing. Idle keep-alive
  sockets do not block checks, but active, interrupted, or unsupported traffic
  does. Cancellation is not proof of completed server work. Unowned uncertainty
  persists for the observation session; owned uncertainty requires confirmed
  process-group absence. Direct clients remain invisible. See
  [request activity](request-activity.md) for supported framing and limits.
- The lifecycle `phase` can remain `healthy` after inference failures
  while confirmation or recovery is pending. The separate `healthy` field becomes
  false and status surfaces show **Inference check failed** until inference
  succeeds. These additions are in source after v1.5.1. The phase alone does not
  prove recent inference success, nor does a shallow success between probes.

The [product plan](product-plan.md) prioritizes verified setup and local workload evidence.

Automatic inference checks require authoritative loaded-model evidence. Ollama
and LM Studio provide it; MLX and Osaurus catalog listings do not. Those adapters
report `residencyUnknown` and defer scheduled checks. Completed inference evidence
expires at the configured interval and is invalidated when the process dies or
is replaced. Historical timestamps remain historical, not fresh verification.
Attached mode cannot identify an external replacement that occurs entirely
between observations.

Validation coverage and tested versions live in the
[validation report](../VALIDATION-REPORT.md).
