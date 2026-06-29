<!-- SPDX-License-Identifier: MIT -->
# Changelog

All notable changes to Hearth are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-28

First public release: a Developer ID signed, notarized build.

### Added
- Managed and attached supervision of Ollama, LM Studio, and mlx_lm on macOS 14+:
  liveness plus readiness health (catching the alive-but-wedged runner a liveness
  check misses), exponential capped backoff, crash-loop detection, IOKit sleep
  prevention, the SMAppService login item, ntfy and local notifications, the
  bearer-token control endpoint, hard-crash orphan recovery, and the `OLLAMA_HOST`
  launchd env-trap fix. Not sandboxed (App Sandbox off, Hardened Runtime on).
  Validated against a real Ollama; see [VALIDATION-REPORT.md](VALIDATION-REPORT.md).
- Scheduled maintenance restart (`maintenanceRestartHours`): proactively cycle a
  healthy runner on an interval to clear the gradual memory creep and VRAM
  fragmentation that degrade a long-running Ollama, whose documented fix is "restart
  it daily." Off by default; floored at one hour; counted off healthy uptime; the
  return to healthy is quiet so a routine cycle does not push a recovered alert.
- Memory and thermal pressure alerts (`memoryAlertPercent`, `thermalAlerts`): turn
  the metrics Hearth already samples into a heads-up before macOS kills the runner
  under memory pressure or sustained thermals throttle it, with an all-clear when
  pressure eases. On by default, with hysteresis so they do not flap.
- Reboot escalation, the last rung of the recovery ladder: when a wedge survives
  process restarts long enough (a driver/GPU-level hang that only a reboot
  clears), Hearth can reboot the Mac and come back with the runner respawned
  clean. Opt-in (`rebootOnWedge`), root-only (the headless daemon), and paranoid:
  only after the runner was healthy this session, only after a sustained failing
  streak, with the reboot history persisted across reboots so a reboot that did
  not help, or a daily cap, stops the loop and notifies a human instead. The
  decision logic is pure and fully unit tested; the actual reboot is a tiny seam.
- `hearth events` and a persisted, line-capped `events.log`, so the supervisor's
  own history (down with the cause, restart scheduled, recovered, crash loop)
  survives a restart and is readable from the terminal, the menu, and the tail in
  `hearth status`.
- `hearth doctor`: a config and environment preflight check.
- `hearth status` and `hearth logs` terminal subcommands.
- An unauthenticated `GET /healthz` liveness route on the control endpoint.
- `make install` (ad-hoc signed local install) and a drag-to-install DMG produced
  by `scripts/release.sh` / `make dmg`.
- Documentation: a configuration reference and a reverse-proxy guide under
  `docs/`.

### Fixed
- Preferences: the ntfy topic and bearer token fields were invisible when empty
  (a grouped-Form quirk), so there was nothing obvious to click. They now show a
  placeholder prompt.
- Crash-loop trap: a runner that crash-looped and then came back was never
  re-probed in the failing state, so it stayed "failing" until a manual restart.
  The slow retry now routes through restarting and recovers.
- Process-controller leaks: terminated children are now reaped (no zombies),
  their entries removed, and their pipe handles closed; the metrics readout no
  longer reports a dead or PID-recycled process; stderr without newlines is
  capped.
- Runner endpoints no longer crash the supervisor on a host with URL-invalid
  characters; the bad host is flagged by `hearth doctor` instead.
- Policy values that would brick supervision (non-positive probe interval, a
  backoff multiplier below 1, a crash-loop threshold below 1) are clamped.
- Teardown synchronously kills a wedged runner group rather than relying on a
  deferred SIGKILL that `exit()` could outrun; the control server drops a
  slow-trickle connection.
- Config reload is serialized by a generation token: rapid reloads (SIGHUP, the
  menu, a Preferences save interleaving at the teardown await) no longer build a
  second engine, second control server, or spawn a second runner.
- ntfy delivery no longer blocks the supervision loop. The engine awaited
  notification delivery on its actor, so a hung ntfy server could stall status,
  control commands, and state for up to a minute; requests now have a short
  timeout and are sent fire-and-forget. The topic is percent-encoded so an
  unusual character no longer silently drops the alert.
- Reboot escalation (`rebootOnWedge`) is flagged by `hearth doctor` as needing the
  root daemon, so an enabled-but-ineffective setting is not silent.
