<!-- SPDX-License-Identifier: MIT -->
# Changelog

All notable changes to Hearth are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## [1.3.0] - 2026-07-11

The two-product release: full Hearth keeps its unsandboxed managed runner and
GPU-wedge recovery powers, while the new Hearth Monitor companion brings useful,
inference-aware attached monitoring to the Mac App Store boundary.

### Added

- **Hearth Monitor 0.1.0**, a separate universal macOS 14+ menu-bar app with only
  App Sandbox and outbound network-client entitlements. It discovers or accepts
  Ollama, LM Studio, mlx_lm, and Osaurus endpoints; monitors multiple local or
  remote runners; distinguishes busy service from outages; optionally runs a
  one-token inference check to catch GPU/inference wedges behind healthy HTTP;
  and provides opt-in local alerts, snooze, Login Items registration, bounded
  incident history, resident-model context, and copied diagnostics.
- An optional read-only bridge from Monitor to a separately installed full
  Hearth. Full Hearth now supports named `controlStatusTokens` that can read
  `/status` and `/metrics` but receive HTTP 403 for start, stop, and restart.
  Monitor verifies token scope and runner identity, stores the credential in its
  private Keychain item, and shows managed restart/reboot coverage without ever
  sending a control command.
- App Store packaging and review assets: a distinct Monitor icon, privacy policy
  and no-collection manifest, Utilities metadata, universal architecture audit,
  distribution-signing script, reviewer checklist, user guide, and a mechanical
  boundary audit that rejects process/privilege/control capabilities or unsafe
  entitlements.

### Changed

- Full Hearth's additive `/status` document reports `mode`, `rebootOnWedge`, and
  the authenticated credential's `credentialAccess`. Its browser page hides
  Start/Stop/Restart when a status-only token is used. Existing primary and named
  control tokens retain full behavior and compatibility.
- The shared token editor can copy a generated token explicitly. Configuration
  diagnostics reject a status credential that reuses a control secret and warn
  when status callers share a credential, preserving independent revocation.
- The local test runner now selects a matching installed Xcode toolchain and
  isolated module cache when Command Line Tools contain a compiler/SDK mismatch.
  CI packages and audits the sandboxed universal Monitor product as its own gate.

### Fixed

- Monitor never closes a confirmed inference incident on shallow HTTP or a busy
  response; real one-token inference must recover. Transient misses preserve the
  healthy-since time, overlapping and stale checks cannot overwrite newer state,
  and one missed check never alerts or enters history.
- Redirects, shared cookies/credentials, oversized responses, stale setup and
  pairing success, corrupt/future settings, duplicate target IDs, Keychain/file
  transaction failures, and misleading local-network/attached-recovery messages
  all have bounded or actionable behavior.
- The UI snapshot gate now hosts views in a real nonvisible AppKit window. This
  caught and replaced a prior renderer that silently emitted unsupported-control
  placeholders while reporting passing tests.

## [1.2.0] - 2026-07-09

The usability release: routine settings no longer disturb a serving runner, the
phone page is a real recovery console, inference-level protection has guided
setup and a one-click test, and retained events and metrics now have a native
incident-history view.

### Added

- The browser phone console now has Start, Stop, and Restart controls, with
  confirmation for destructive actions, correct phase-based enablement, a
  forget-token action, model-fit warnings, the detailed last failure, and the
  ten most recent Hearth activity lines. Control actions continue to use bearer
  authentication and named-token auditing. `/status` adds the optional,
  bounded `recentEvents` field; it never contains the runner log.
- Guided deep-probe setup in Preferences: enable inference-level health checks,
  discover the models the configured runner reports, choose from a model picker
  ordered smallest-first when sizes are available, and run the real one-token
  probe before saving. Ollama uses `/api/tags`; LM Studio, mlx_lm, and Osaurus
  use their model-list APIs.
- A native **History\u{2026}** window groups down-to-recovered events into
  incidents, reports recovery time, summarizes incidents and crash loops, and
  plots retained system memory and runner RSS with restart markers. The view is
  entirely local and can copy a concise support summary.

### Changed

- Notification destinations and pause state, memory and thermal alert settings,
  heartbeat, and the control endpoint now reload live in the menubar app without
  stopping the managed runner, unloading models, or interrupting inference.
  Preferences previews changes that still require a runner or supervision
  restart and labels the Save action accordingly.

## [1.1.0] - 2026-07-04

The first feature release after 1.0, focused on making the runner's memory
behavior legible: Hearth now names a model that keeps running the Mac out of
memory, and its metrics carry the runner kind and a bounded restart category.

### Added

- Model-fit guidance: when a model is resident at repeated memory-related crashes
  (an out-of-memory kill, or a crash as it loads) within a window, Hearth flags
  it as likely too large for this Mac instead of letting it crash-loop silently.
  It sends a "Model likely too large" alert naming the model, shows a menubar
  warning, and lists it under `oversizedModels` on `/status`. Tuned by
  `modelOOMThreshold` (default 2) and `modelOOMWindowSeconds` (default 1800); set
  the threshold to 0 to disable. Model names are kept off Prometheus (they are
  high-cardinality) and confined to the bounded status, menu, and alert surfaces.
- `hearth_runner_info{runner="ollama"}` Prometheus metric (a low-cardinality info
  gauge) and a `runner` field on `/status`, so a dashboard can tell which runner
  each Hearth supervises.
- `hearth_last_restart{category}` Prometheus metric and `lastRestartCategory` on
  `/status`: a bounded restart category (wedged, crash, oom, signal, memory-limit,
  maintenance, manual, binary-upgrade) that covers deliberate restarts too, not
  just failures like the existing `hearth_last_down`. Closes the two open items in
  the observability roadmap.

## [1.0.0] - 2026-07-02

The 1.0 release. Hearth's core, keeping a local LLM runner alive through
crashes, wedges, and GPU hangs, has been validated end to end against a real
Ollama (see VALIDATION-REPORT.md, including a live GPU crash from image
generation that only the deep probe caught) and now carries a written stability
contract (docs/stability.md). This release is the road-to-1.0 hardening pass:
closing the gaps a new user hits in week one, and writing down what 1.0
promises.

### Added

- Unknown config keys warn instead of being silently ignored, with a
  did-you-mean suggestion for near misses (`probemodel` suggests `probeModel`).
  Surfaced by `hearth doctor` and the menu's config-issues line; always
  warnings, never errors, so a config from a newer Hearth still loads.
- `hearth doctor` names every supervision layer installed (root daemon, login
  agent, menubar login item), reports which pid holds the single-instance lock,
  and warns with exact removal commands when layers have stacked up.
- `hearth update` also upgrades Hearth itself when it was installed with the
  Homebrew cask, and says how to relaunch the running instance onto the new
  build. A source install is told how to update instead of skipped silently.
- Preferences now covers the metrics proxy (toggle and port), named control
  tokens (a sheet editor with per-row Generate), the busy timeout, the memory
  limit watchdog, thermal alerts, the memory alert percent, and the heartbeat
  interval. The reboot escalation family stays config-file-only on purpose.
- docs/stability.md: the stability contract for 1.x, declaring the config
  schema, CLI subcommands and exit codes, control API fields and routes,
  Prometheus metric names, and the event-log phrases `events --stats` parses
  as stable, and naming what is experimental. Tests pin the /status key set
  and round-trip the frozen event phrases so an accidental break fails CI.

### Changed

- `hearth update` with a non-Ollama runner now points at that runner's own
  updater and continues to the Hearth self-update phase, instead of exiting
  with an error before doing anything.

## [0.9.0] - 2026-07-02

The beginner and operator release, shaped by four independent audits in two
days: a beginner-lens usability pass, two adversarially verified bug audits
covering the whole program, and a four-angle feature audit (internal roadmap,
community demand, competitive landscape, personas). The headline is that
recovery became something you cannot feel: models are warmed back up after a
restart, a busy server is never mistaken for a wedged one (and a fake-busy
wedge is still caught), routine restarts can drain in-flight work first, and
the whole story now reads in plain language for someone who installed Ollama
last week. Under the hood, more than twenty confirmed defects from the audits
were fixed, including a GPU-memory leak on the shutdown path and engine races
around user restarts.

### Added
- Model warm-up after restart (`warmModelsAfterRestart`): the models that were
  resident before a restart are loaded again once the runner is healthy, so
  recovery does not hand the next request a multi-gigabyte cold start. A model
  that fails to load triggers a "Models not restored" alert. Warm-up is skipped
  when the runner had just crashed loading those models (an out-of-memory kill,
  or a crash right after a warm-up), so a model too big for the Mac cannot drive
  a GPU crash loop; Hearth leaves the runner idle-but-alive and alerts you to
  load a smaller model instead.
- Busy is a first-class state: a runner answering 503 (a full queue) is
  serving, not wedged. It is never restarted for being busy, the menu and
  `hearth status` show "Healthy (busy)", and `/status` carries a `busy` field.
- A dead-man's-switch heartbeat (`heartbeatURL`): while the runner is healthy,
  Hearth GETs an Uptime Kuma push monitor or healthchecks.io URL on an
  interval, so the dashboard you already run does the alerting when the pulse
  stops.
- A daily maintenance window (`maintenanceWindow: "HH:MM-HH:MM"`): scheduled
  maintenance restarts wait for the window instead of landing mid-afternoon.
- Pause Notifications (menu, or `notificationsPaused`): vacation mode that
  silences every channel without touching its settings.
- Metrics grew bounded labels: the active phase, the last failure category
  (`wedged`, `crash`, `oom`, `signal`), busy, and deep-probe status are now in
  `/metrics` and `/status` for Grafana and friends.
- The FAQ documents running two runners with two Hearth instances (the
  single-instance lock is keyed to the config file).
- A memory watchdog (`runnerMemoryLimitMB`): a healthy managed runner whose
  resident size crosses the ceiling is restarted before the RSS-creep slow
  death becomes a wedge, with a "Memory limit restart" alert. pm2's
  max_memory_restart, translated to unified memory.
- `hearth update`: runs `brew upgrade ollama` and then makes sure a running
  Hearth actually adopts the new binary, via restartOnBinaryChange, the
  control endpoint, or printed instructions.
- Osaurus (the native MLX server for Apple Silicon) is the fourth supervised
  runner: `runner: "osaurus"`, OpenAI-compatible probing on port 1337,
  attached mode recommended like LM Studio.
- An opt-in tokens-per-second tap (`metricsProxyEnabled`): a transparent
  relay in front of the runner that scans responses for the throughput
  numbers the runner itself reports and feeds `hearth_tokens_per_second`,
  `hearth_generation_tokens_total`, and `hearth_generation_requests_total`
  in `/metrics`. Bytes pass through untouched; nothing scanned is stored.
- Graceful drain (`drainSeconds`): with the metrics proxy watching traffic, a
  routine restart (scheduled maintenance, a binary upgrade) waits for
  in-flight generations to finish, bounded by the budget, instead of cutting
  one off mid-token. Failure restarts never wait.
- `hearth proxy-setup`: generates a ready-to-run authenticating Caddy reverse
  proxy config from the actual Hearth config, with a real random bearer token
  and the tailnet address when one is present, making the documented
  reverse-proxy pattern turnkey.
- `controlHost: "tailscale"`: a sentinel that resolves to this Mac's tailnet
  IPv4 at bind time (loopback when none is found), so the control endpoint
  follows the tailnet instead of a hand-copied address going stale.
- Named control tokens (`controlTokens`) with an audit trail: a shared control
  endpoint can give each caller its own token, and every start/stop/restart is
  logged with the token's name (`Control: restart requested by token
  "phone-kitchen"`). The unnamed `controlToken` still works, recorded as
  `default`. All tokens are checked constant-time, no early out.
- `hearth events --stats`: analytics over the retained event log (down count,
  crash loops, mean and longest recovery time, and a cause histogram).
- Every status surface now shows the data the feature tiers produce: the phone
  page and `hearth status` show busy, the last failure category, and tokens per
  second; `/status` carries `tokensPerSecond` and `generationTokensTotal`; the
  menu shows a throughput line when the metrics proxy is on.
- Opt-in `alertsIncludeLogTail`: down and failing alerts can carry the
  runner's last log lines (bounded, sanitized) so the alert itself says why.
  Off by default because log lines are runner content and alerts leave the
  box; the doctor warns when the flag rides the public ntfy.sh, and the
  README's privacy statement names the exception explicitly.
- EXPERIMENTAL `rebootViaHelper` and the `hearth-reboot-helper` root daemon:
  the least-privilege split for reboot-on-wedge. The helper's entire API is
  "reboot, if you are the configured uid and not too often" on a root-owned
  socket with peer verification and its own rate limit, so the headless
  supervisor need not run as root to keep the recovery ladder.
  `scripts/install-reboot-helper.sh` installs it; the classic root daemon
  remains the default.
- A beginner-oriented FAQ (`docs/faq.md`): is Hearth for me, which mode do I
  want, how do I know it is working, does my data leave the machine, and how to
  uninstall. Troubleshooting gained entries for the crash loop, spawn failures,
  and the "stuck (still running, but not answering)" wording.
- The menu now carries next steps in its two not-recovering states: a crash
  loop points at Open Logs and `hearth doctor`, and a watched (attached-mode)
  runner that is down says plainly that Hearth will not start it, with a
  one-click switch to managed. Both conflict warnings (brew services, a runner
  already on the port) offer a one-click "Watch the Existing Runner Instead".
- A `ModeKind` type owns the managed/attached user-facing vocabulary (status
  phrase, Preferences picker labels), mirroring `RunnerKind`, and the menu
  guidance wording lives in `StatusText` where tests lock it down.
- `hearth mode managed|attached`: explicitly switch whether Hearth starts and
  restarts the runner or watches a runner started by something else. Switching to
  attached mode refuses by default unless a compatible runner is already serving;
  use `--force` only when you intend to start that runner yourself later.
  `--daemon` applies the same edit to `/etc/hearth/config.json` when run with
  sudo. The command edits the config only, so after a change it prints how to
  reload a running Hearth (Reload Config or SIGHUP for the app, `launchctl
  kickstart` for the root daemon).

### Changed
- `hearth setup` now makes the common managed-vs-attached choice more assistive
  without silently guessing at runtime. On a fresh config, a known launchd-managed
  Ollama (`brew services`) whose server is actually answering makes setup choose
  attached mode; a loaded-but-silent job, a manual runner, or an unknown listener
  still stops setup with explicit commands.
- `hearth doctor` now distinguishes a compatible already-running runner from an
  unknown listener on the port, and attached mode tells you whether nothing is
  serving or the service is not the configured runner.
- A user-facing copy pass for people newer to local LLMs: crash reasons are
  said in plain words with the raw signal or exit code in parentheses, the
  wedge label reads "stuck (still running, but not answering)", the status
  line says "started by Hearth" or "watched (started elsewhere)" instead of
  managed/attached, notification bodies end with where to look next (naming
  CLI equivalents so headless setups are not pointed at a menu), the Advanced
  preferences collapse behind a disclosure, and the README leads with what
  Hearth does, an is-it-safe-to-install answer, and an uninstall line.
- A manual restart of an already-healthy runner comes back quietly instead of
  announcing a spurious "Runner recovered"; a manual restart of a down or
  failing runner still announces the all-clear.
- Foreign-runner detection (the "Already running" warning) now requires the
  runner's own readiness endpoint to answer with success; an unrelated service
  holding the port is a port conflict, not a reason to suggest attached mode.
- A typo'd subcommand (`hearth statuss`) prints an error and exits 2 instead
  of silently launching the menubar agent; flag-style launch arguments from
  Finder and Xcode are exempt.
- Start at Login auto-registers once, on the genuine first run; a config
  reload no longer re-enables it after the user turned it off.
- `initialBackoffSeconds` and `maxBackoffSeconds` are floored (0.1s, and the
  initial backoff respectively) like their neighbors, and `hearth doctor`
  warns on a non-positive initial backoff.
- GitHub Actions workflows use `actions/checkout@v5`.

### Fixed
- The shutdown group SIGKILL skipped the most common leak shape: a leader that
  exited on SIGTERM (an unreaped zombie) while a wedged group member survived
  holding GPU and unified memory. It now gates on the deferred-kill rule
  (unreaped means unrecycled) and takes the group down.
- Engine races around user restarts: a probe that was in flight across a
  restart could mark the fresh child healthy with the old child's report
  (skipping startup grace), and a restart during backoff spawned a child that
  went unprobed until the backoff elapsed. Control actions now invalidate
  stale reports and wake the loop.
- A `waitpid` failure was misreported as a SIGKILL ("force-killed") exit; it
  now reports an unknown exit, and a failed reap no longer drops the
  crash-recovery record for a possibly live process.
- Out-of-memory stderr signatures only count for an abnormal exit, so a runner
  that once logged an allocation complaint and then exited cleanly is not
  reported as an OOM kill. An attached-mode hang now reads as stuck rather
  than an invented "unknown exit".
- `hearth status` no longer crashes on an IPv6 (Tailscale) `controlHost`; the
  URL is bracketed and falls back to the reduced status, and the advertised
  phone-access URL brackets IPv6 too.
- The readiness probe client refuses HTTP redirects, so a misbehaving runner
  cannot have another host's answer scored as its health or replay the deep
  probe body off-box; response bodies are drained in chunks with the same
  hard size cap.
- ntfy topics are percent-encoded strictly (a slash cannot change the path),
  and ntfy, webhook, and runner-log-open failures each surface as one stderr
  line instead of failing silently. The event log serializes its appends, the
  standby lock retries an interrupted `flock`, the privilege-drop spawn shim
  does its non-async-signal-safe work before the fork and returns fork errors
  as negated errno, and the menubar menu no longer crashes when opened in the
  instant before the first config load completes.
- The smoke test's power-assertion check is scoped to the test agent's pid,
  so a real Hearth login agent on the same Mac no longer fails it.
- With `host` set to `0.0.0.0` (or `::`), readiness probes now dial loopback
  instead of the wildcard address, which is not connectable. `hearth wait-ready`,
  `hearth doctor`, `hearth setup`, the attached-mode gate, and the supervisor's
  own health probe all work again for a LAN-open runner; the managed runner still
  binds every interface.

## [0.8.0] - 2026-07-01

Least privilege, plus a security hardening pass from a third independent audit (a
red-team across six attacker personas). The headline is `runnerUser`: the root
daemon drops the runner to an unprivileged account while staying root for the
reboot capability, verified end to end with full GPU access on Apple Silicon. The
root managed-daemon path now fails closed until `runnerUser` is set; non-root app
and login-agent behavior is unchanged. The README is also restructured into a
tighter tour, with the operational detail moved into `docs/`.

### Added
- `runnerUser` (config): when Hearth runs as the root daemon in managed mode, it
  drops the spawned runner to this account while staying root itself (so it keeps
  the reboot capability), so a runner or malicious-model compromise no longer lands
  as root. Managed root-daemon spawn now refuses to run until this is set to a
  real non-root account. Hearth supplies the account's `HOME`/`USER`/`LOGNAME`
  automatically. Verified end to end on Apple Silicon: the dropped runner still
  reaches the Metal GPU from the non-GUI daemon session.
- `rebootOnlyOnProcessFailure` (config, off by default): when on, a reboot fires
  only if the failing streak included a real process exit, never for a pure "alive
  but not answering" wedge, so a runner that only controls its HTTP responses cannot
  drive the machine into a reboot. Opt-in, for operators who do not fully trust the
  runner; a pure wedge then escalates to a notification instead.

### Security
- Hearth writes its own config, runner-state, reboot-history, and metrics-history
  files as mode `600` in a `700` directory, and re-tightens an already
  world-readable config on load. The control token and ntfy topic are no longer
  readable by other local users, so the app no longer relies on the install script
  to harden files it writes itself.
- The runner HTTP client caps a response body at 16 MB and sets a hard resource
  timeout, so a hostile or wedged runner cannot exhaust the supervisor's memory or
  hold a probe open forever by trickling bytes under the stall timeout.
- Reboot-on-wedge is refused in attached mode: Hearth never reboots the Mac over a
  runner it only monitors and does not own.

## [0.7.0] - 2026-06-30

Reach and robustness, plus a hardening pass from two independent audits: the deep
probe now covers LM Studio and mlx_lm, the `hearth` CLI lands on your PATH after
install, and the root daemon applies config cleanly and rotates its own logs.

### Added
- The Homebrew cask and `make install` put the `hearth` CLI on your PATH (a `binary`
  stanza / a symlink into `/usr/local/bin`), so the `hearth doctor`, `hearth status`,
  and `hearth setup` commands the docs use resolve on a fresh install.
- The deep readiness probe works on LM Studio and mlx_lm too (a one-token OpenAI chat
  completion), not only Ollama, instead of silently passing on those runners.
- The root daemon installs a newsyslog drop-in so its own
  `/var/log/hearth.{out,err}.log` rotate instead of growing unbounded.

### Changed
- The deep readiness probe no longer sends `keep_alive`, so the probed model's
  residency follows the runner's own `OLLAMA_KEEP_ALIVE` policy rather than a five
  minutes the probe imposed.

### Fixed
- The root-daemon installer writes `/etc/hearth/config.json` as mode `600` (it holds
  the control token) and re-tightens an already-existing one.
- The headless daemon handles SIGHUP as a clean restart (via launchd KeepAlive)
  rather than a default-disposition terminate that briefly orphaned the child, and
  the root-daemon doc no longer claims SIGHUP reloads config without restarting.
- `hearth doctor` now warns when the control endpoint is bound to `0.0.0.0`, when the
  control token is the placeholder or under 16 characters, and when `ntfyTopic` is
  still the placeholder. The example config ships `ntfyTopic: null`, so a verbatim
  copy cannot post to a public relay.
- A failed spawn (a bad or incompatible runner binary) now reports the specific error
  in the status, menu, and `/status` instead of a bare "down".
- The first-run config template writes the detected binary into the selected runner's
  field (via a setter shared with `hearth setup`), and the integrating guide's
  example link pointed Hob at Hearth's own repo.

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
