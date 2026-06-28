<!-- SPDX-License-Identifier: MIT -->
# Changelog

All notable changes to Hearth are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

## [0.1.0]

First Developer ID signed, notarized build. Managed and attached supervision of
Ollama, LM Studio, and mlx_lm on macOS 14+; liveness plus readiness health,
exponential capped backoff, crash-loop detection, IOKit sleep prevention,
SMAppService login item, ntfy and local notifications, the bearer-token control
endpoint, hard-crash orphan recovery, and a not-sandboxed (App Sandbox off,
Hardened Runtime on) distribution. Validated against a real Ollama; see
[VALIDATION-REPORT.md](VALIDATION-REPORT.md).
