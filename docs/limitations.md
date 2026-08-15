<!-- SPDX-License-Identifier: MIT -->
# Known limitations and design choices

Stated up front on purpose. Some are genuine limitations; others are deliberate
scope choices, because Hearth supervises a runner, it is not the runner, and it
does not reimplement the operating system.

- Restarting the runner clears a process-level wedge, not a driver- or GPU-level
  one ([ollama#8594](https://github.com/ollama/ollama/issues/8594)); those need a
  full reboot. A respawn clears more on Apple Silicon and Metal than on the
  discrete-GPU setups in those reports, but it is not a cure-all. For a headless
  box, the opt-in reboot escalation
  ([Recovering a wedge a restart cannot](running-headless.md#recovering-a-wedge-a-restart-cannot))
  automates the reboot that does, with a loop guard and a give-up-and-notify floor.
- Validated against a real Ollama 0.30.11 (see
  [VALIDATION-REPORT.md](../VALIDATION-REPORT.md)): cold start, external kill, the
  alive-but-wedged case via SIGSTOP, clean process group teardown with no
  orphaned `llama-server`, attached mode, and hard-crash orphan recovery (a
  SIGKILLed Hearth's leaked runner group is swept on the next launch). Managed
  mlx_lm was revalidated against MLX-LM 0.31.3 and MLX 0.32.0 with a genuinely
  cold model download, real inference, external SIGKILL, restart, and inference
  after model reload. LM Studio was validated in attached mode (the report has
  the details).
- Out of memory classification is a heuristic and is UNVERIFIED against a real
  out of memory kill, which could not be induced on the 128 GiB unified-memory
  development hardware: no downloaded model is large enough to exhaust it, and
  manufacturing memory pressure risks the whole machine. The signatures are
  confirmed absent from a healthy Ollama's output (so they do not
  false-positive), but not confirmed to fire on a real Metal OOM. If you have a
  memory-constrained Apple Silicon Mac and a model too large for it,
  `scripts/capture-oom.sh <model>` captures the real stderr signature and checks
  it against the shipped list, so the fixture can be contributed and this note
  retired. The signatures are also only consulted for an abnormal exit (a signal
  or a non-zero code): a runner that logged an allocation complaint and then
  exited cleanly is reported as a clean exit, not an OOM.
- If Hearth itself is killed without the chance to run its teardown (a hard
  SIGKILL of the agent), the runner process group it spawned keeps running until
  Hearth next launches. On launch Hearth recognizes the leaked group by its
  recorded PID and process start time and sweeps it before starting a fresh
  runner, so the leak self-heals on restart rather than accumulating. The
  residual gap is only the window between the crash and the next launch. A clean
  quit, a SIGTERM, or a normal restart reaps the whole group immediately.
- The power assertion prevents idle sleep, which keeps a Mac that would otherwise
  sleep on idle (a desktop, or a plugged in laptop with the lid open) awake and
  serving. Keeping a laptop serving with the lid closed on battery is a separate,
  privileged concern and is not implemented.
- Timers are wall-clock, not serving-clock. If the Mac does sleep (forced, or a
  laptop lid close), a long sleep ages the runner in real time: supervision
  self-corrects on wake (a restart that came due mid-sleep fires immediately), but
  an enabled maintenance restart can land right after wake, and the crash-loop
  window counts real time rather than time spent serving. There is no
  `IORegisterForSystemPower` hook; the drift is cosmetic, not a recovery gap.
- LM Studio works in attached mode only. `lms server start` exits immediately (the
  server runs in LM Studio's own background process), so a managed runner thrashes;
  `hearth doctor` and the menu flag it. Start LM Studio's server yourself and let
  Hearth watch it.
- The control endpoint authenticates with bearer tokens rather than user accounts
  and is meant to live behind a VPN, not on the open internet. It adds peer
  lockouts, connection caps, and browser hardening, but it is not an internet-edge
  identity service or TLS terminator.
- An inference timeout alone cannot prove a wedge while client work is invisible:
  a legitimately long generation can occupy the same queue. Deep-probe failures
  therefore alert but do not restart until the metrics proxy has carried real
  client traffic and reports the runner idle. Process exits and shallow API
  failures retain automatic recovery without the proxy.
