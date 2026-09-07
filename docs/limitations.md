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
- The proxy counts open TCP connections, not active generation requests. A pooled
  connection or stalled request can defer inference checks; observed proxy traffic
  does not establish visibility into direct clients. The interaction with probe
  cadence and `busyTimeoutSeconds` needs targeted validation.
- The current supervisor phase can remain **Healthy** after repeated inference
  failures when automatic recovery is withheld. Inspect inference alerts and
  verify generation; the phase alone does not prove recent inference success.

The [product plan](product-plan.md) prioritizes traffic visibility and accurate
inference status.

Validation coverage and tested versions live in the
[validation report](../VALIDATION-REPORT.md).
