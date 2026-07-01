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
  SIGKILLed Hearth's leaked runner group is swept on the next launch). mlx_lm has
  since been validated in managed mode against a live `mlx_lm.server`, and LM
  Studio in attached mode against a live server (the report has the details).
- Out of memory classification is a heuristic and is UNVERIFIED against a real
  out of memory kill, which could not be induced on high unified-memory hardware.
  The signatures are confirmed absent from a healthy Ollama's output (so they do
  not false-positive), but not confirmed to fire on a real Metal OOM.
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
- The control endpoint is unauthenticated beyond a shared bearer token and is
  meant to live behind a VPN, not on the open internet.
