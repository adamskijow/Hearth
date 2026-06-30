<!-- SPDX-License-Identifier: MIT -->
# Changelog

All notable changes to Hearth are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- The deep readiness probe no longer sends `keep_alive`, so the probed model's
  residency follows the runner's own `OLLAMA_KEEP_ALIVE` policy rather than a five
  minutes the probe imposed.

### Fixed
- The root-daemon installer writes `/etc/hearth/config.json` as mode `600` (it holds
  the control token) and re-tightens an already-existing one.
- `hearth doctor` now warns when the control endpoint is bound to `0.0.0.0`, when the
  control token is the placeholder or under 16 characters, and when `ntfyTopic` is
  still the placeholder. The example config ships `ntfyTopic: null`, so a verbatim
  copy cannot post to a public relay.
- The integrating guide's example link pointed Hob at Hearth's own repo.

## [0.6.0] - 2026-06-30

A deeper health check: an optional probe that runs a real one-token generation, so a
wedged model runner that still answers the shallow endpoint (a GPU or model-load
hang) is caught and restarted, not just a frozen process.

### Added
- Optional deep readiness probe (`probeModel`). The default `/api/version` probe
  only proves the HTTP server answers; it misses a wedged model runner that still
  responds there (a GPU or model-load hang, the failure most people actually hit).
  Set `probeModel` and Hearth periodically runs a one-token generation against it,
  so an inference-level wedge is caught and restarted, while a working runner still
  passes. Off by default (it names a model and does GPU work); tuned with
  `deepProbeIntervalSeconds` and `deepProbeTimeoutSeconds`. Covered by a unit test
  through the engine and a live run against a stand-in runner that answers
  `/api/version` but hangs `/api/generate`; not yet validated against a real wedged
  Ollama.

## [0.5.0] - 2026-06-30

Onboarding: the most common newcomer, who already runs the official Ollama app, now
gets told about the port collision and resolves it in one click, and is reassured
that their apps need no changes.

### Added
- First-run collision detection with a one-click fix. When a runner Hearth did not
  start is already serving the port (most often the official Ollama app, which
  auto-runs the server), managed mode would silently fight it for the port. The
  welcome window and the menu now flag it with a **Switch to Attached Mode** button
  that resolves it in one click (Hearth watches the running one instead of fighting
  it), and `hearth doctor` reports the same fix.
- The welcome window now reassures a new user that their apps need no changes, they
  keep talking to the runner as they do now, and several apps and models can share
  the one runner.

## [0.4.0] - 2026-06-30

Tooling and observability: ready-made monitoring recipes, a reproducible
wedge-recovery demo, isolated test and demo instances, and a reorganized README.

### Added
- Ready-made monitoring recipes in `deploy/`: an importable Grafana dashboard built
  against Hearth's `/metrics`, a Prometheus scrape config with alert rules (the
  wedge and memory pressure), and two Uptime Kuma monitors (`/healthz` liveness and
  a `/status` readiness keyword).
- `HEARTH_DATA_DIR`: an environment override that moves all of Hearth's state and
  logs under one directory, so a throwaway, demo, or test instance is fully isolated
  from a real one (the support and log locations are otherwise fixed under the home
  directory and shared across instances). Pairs with `HEARTH_CONFIG`.
- `make demo`: a narrated, isolated wedge-recovery demo against the stand-in runner
  (freeze it alive with `SIGUSR1`, watch Hearth catch it by readiness and recover),
  with a VHS tape (`assets/wedge-recovery.tape`) to record it as the README's GIF.

### Changed
- The README was reorganized and shortened: a visible table of contents and a docs
  index, overlapping sections merged, Testing, Releasing, and Known limitations
  moved into `docs/`, and the intro now answers why a Mac-native tool (Docker on
  macOS is CPU-only) rather than a launchd plist or a hand-rolled watchdog.

## [0.3.0] - 2026-06-30

Networking and runner-config quality of life: reaching the runner from another
machine, and carrying hand-tuned runner settings in the config rather than a
launchd plist.

### Added
- Runner reachability: `hearth doctor` now reports whether the runner is reachable
  only from this Mac (the loopback default) or from the network, with the exact URL
  another computer would use and a firewall reminder. The menu shows a "Reachable
  at" line when the runner is up and bound to a routable address. This turns the
  common "I can't reach Ollama on my other computer" into a guided fix.
- `runnerEnv`: a config map of extra environment variables for a managed runner
  (`OLLAMA_LOAD_TIMEOUT`, `OLLAMA_KEEP_ALIVE`, and the like), so a hand-tuned setup
  is a config key rather than a launchd plist edit. Editable in Preferences via a
  "Set Env" editor where the variable name is a dropdown of the runner's known
  variables (with a Custom entry for anything off-list) and a one-line description,
  or by hand in the config file. Hearth still derives `OLLAMA_HOST` from
  `host`/`port`, and `hearth doctor` warns if `runnerEnv` tries to set it.

## [0.2.0] - 2026-06-30

A large follow-up focused on multi-app use, observability, and a smoother first
run, on top of everything in 0.1.0.

### Added
- Single-instance guard: only one Hearth supervises a given config at a time. The
  menubar app bows out if another instance is already supervising, and a headless
  launch agent waits as a hot standby and takes over only if the holder exits, so
  two Hearths (or the menubar app alongside a login agent) never fight over the
  runner.
- `hearth setup`: one command to detect the runner, point the config at it, install
  a login agent, and wait for the runner to be ready.
- `hearth install-agent` / `hearth uninstall-agent`: install or remove a per-user
  LaunchAgent that keeps Hearth running headless at login, no sudo. This replaces
  the hand-rolled plists an app would otherwise ship to depend on Hearth.
- `hearth wait-ready`: block until the runner answers, then exit 0 (1 on timeout),
  so a dependent app can gate its own startup on the runner being up.
- `hearth status --json`: machine-readable status with a top-level `healthy`
  boolean, for an agent verifying a setup.
- A Prometheus `/metrics` endpoint on the control endpoint (behind the token), so
  Hearth can be scraped into Grafana or Uptime Kuma.
- Generic webhook notifier (`webhookURL`): POST a small JSON status body on each
  event, to wire Hearth into your own automation alongside ntfy.
- Restart on runner binary upgrade (`restartOnBinaryChange`): a managed runner
  adopts a new binary after a `brew upgrade` instead of serving the old one forever.
  Off by default.
- Competing-manager detection: `hearth doctor` and the menu flag another launchd
  job (such as `brew services`) keeping the same runner alive, which would fight a
  managed Hearth the way a second Hearth would.
- Metrics history and `hearth metrics`: a retained ring of memory and thermal
  samples with a trend and a sparkline, so the slow creep a maintenance restart
  exists to clear is visible.
- A browser status page at the control endpoint's `GET /`, plus a scannable
  phone-access QR in the menu, for checking status from a phone with no app.
- A first-run welcome window: it orients a new user to the menubar, confirms what
  was found (or makes a missing runner actionable with a copyable install command),
  and asks for notification permission with context instead of a cold prompt at
  launch.
- An "Integrating with Hearth" guide (`docs/integrating.md`) for apps that depend on
  a local runner.
- Project-health files (a security policy, code of conduct, issue and PR templates),
  README badges, and a comparison table against launchd KeepAlive and brew services.
- A tag-triggered release workflow.
- LM Studio (attached) and mlx_lm (managed) validated against live servers, with
  config diagnostics surfaced in the menu.

### Changed
- The menu got a polish pass: a scannable phone-access QR gated on a genuinely
  reachable address (it no longer advertises a localhost URL a phone cannot use), a
  "Copy Diagnostics" action, the conventional Start / Stop / Restart order, and
  capitalization fixes.
- First launch no longer fires a cold notification-permission prompt; the welcome
  window asks with context.
- The README was tightened: a leaner intro, the full inline config dump deferred to
  the reference, and corrected validation claims.

### Fixed
- A pre-publication audit fixed a stored XSS on the browser status page (runner
  model names went into innerHTML unescaped, on the surface that holds the bearer
  token) and several stale docs and scripts.
- An adversarial sweep fixed five bugs: a thermal "unknown" reading clearing an
  active alert and flapping; a runner left a zombie when the process controller was
  deallocated during a config reload; supervisor state and metrics sampled before
  the auth check on every request; the reboot loop guard failing open on a lost
  history file (now backstopped by a kernel boot-time check); and a misleading
  metrics cadence message.
- The runner model parsers are hardened against malformed, truncated, and
  wrong-type responses.
- Preferences "Copy phone URL" no longer copies an unreachable localhost URL.

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
