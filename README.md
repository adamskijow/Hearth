<p align="center">
  <img src="assets/hearth-banner.svg" alt="Hearth: keeps your local LLM runner alive on a headless Mac" width="100%">
</p>

# Hearth

<p align="center">
  <a href="https://github.com/adamskijow/Hearth/actions/workflows/ci.yml"><img src="https://github.com/adamskijow/Hearth/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/adamskijow/Hearth/releases/latest"><img src="https://img.shields.io/github/v/release/adamskijow/Hearth?sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/adamskijow/Hearth" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white" alt="macOS 14+">
</p>

Hearth is a background supervisor that keeps a local LLM runner (Ollama, with LM
Studio and mlx_lm support) alive and serving on a headless Mac.

It is an availability layer, not an inference layer. Hearth watches the runner,
restarts it when it dies or wedges, keeps the Mac awake while it is meant to be
serving, and tells you when something goes wrong. It is not a chat UI or a
replacement for Ollama or LM Studio; it supervises the runner you already run. The
runner is an opaque child process that Hearth owns; it reads the runner's API and
logs only to judge whether it is healthy.

## Contents

**Start here** &nbsp; [Quickstart](#quickstart) · [Why this exists](#why-this-exists) · [Requirements](#requirements) · [Install and build](#install-and-build)

**Use it** &nbsp; [Configure](#configure) · [How it works](#how-it-works) · [Remote control](#remote-control) · [Troubleshooting](#troubleshooting)

**Run it headless** &nbsp; [Running headless](#running-headless) · [Recovering a wedge a restart cannot](#recovering-a-wedge-a-restart-cannot) · [Security and exposing the runner](#security-and-exposing-the-runner)

**Project** &nbsp; [Architecture](#architecture) · [Roadmap](#roadmap) · [Contributing](#contributing) · [License](#license)

## Documentation

The README is the tour. Deeper detail lives in `docs/`:

- **[Configuration reference](docs/configuration.md):** every config key, its default, and what it does.
- **[Integrating with Hearth](docs/integrating.md):** for an app that wants to depend on a local runner being up.
- **[Reverse proxy and TLS](docs/reverse-proxy.md):** reaching the runner or the control endpoint securely from off this machine.
- **[Development](docs/development.md):** running the test suite and cutting a release.
- **[Known limitations and design choices](docs/limitations.md):** what Hearth does not do, and why.

## Quickstart

If you already run Ollama on this Mac:

```
brew install --cask adamskijow/tap/hearth   # or: git clone the repo, then make install
open /Applications/Hearth.app
```

A flame appears in the menubar. Hearth auto-detects Ollama at the Homebrew path,
starts supervising it, and keeps the Mac awake while it serves. That is the whole
setup. To check it from a terminal:

```
hearth doctor    # config and environment preflight
hearth status    # phase, uptime, restarts, resident models
```

If your runner is elsewhere or you want LM Studio or mlx_lm, the remote control
endpoint, or pressure alerts, see Configure below. If something looks off, jump to
Troubleshooting.

## Why this exists

If you run a local model server on a Mac you leave in a closet, the usual fix is a
launchd plist or `brew services` with `KeepAlive`, which relaunches the runner when
the process exits. That handles a clean crash. It does not handle the failure that
actually wastes your afternoon: the runner is still running, but no longer answering.

That "alive but wedged" state is common and well reported: the runner hangs after a
few requests with no error ([ollama#6616](https://github.com/ollama/ollama/issues/6616)),
the GPU stops responding and "the service needs to be rebooted"
([Framework](https://community.frame.work/t/ollama-model-runner-unexpectedly-stopped-gpu-hang/76220)),
or Ollama silently reverts to CPU and spins for hours
([ollama#8594](https://github.com/ollama/ollama/issues/8594)). The process is up the
whole time, so a **liveness** check ("is the PID there?") is satisfied and launchd
does nothing.

Hearth probes **readiness** ("does the API actually answer in time?"), so it catches
the wedge, not just the crash: launchd restarts the runner when it dies, Hearth also
restarts it when it wedges. It also handles what a process supervisor was never meant
to: keeping the Mac awake while serving, sidestepping the `OLLAMA_HOST` listen-address
trap, and alerting you when something breaks. And it runs on top of launchd, not
instead of it (the login agent that keeps Hearth alive is a launchd job), to make a
local runner behave like a real, always-on service on a machine nobody is sitting at.

## Requirements

- macOS 14 or later.
- An existing runner install. Ollama is the default; LM Studio and mlx_lm are
  also supported. Hearth supervises the runner, it does not install it.
  - Ollama: expected at `/opt/homebrew/bin/ollama` (the Apple Silicon Homebrew
    location). If yours is elsewhere, for example `/usr/local/bin/ollama`, set
    `ollamaBinaryPath`.
  - LM Studio: set `runner` to `lmstudio` and `lmStudioBinaryPath` to your `lms`
    CLI, and use **attached** mode. Managed mode does not work, because
    `lms server start` exits immediately (the server runs in LM Studio's own
    background process), so a managed runner would thrash; `hearth doctor` and the
    menu flag this. Start LM Studio's server yourself and let Hearth watch it.
  - mlx_lm: set `runner` to `mlx` and `mlxBinaryPath` to your `mlx_lm.server`.
    Managed mode is validated. Note that `mlx_lm.server` needs at least one MLX
    model in your HuggingFace cache (its `/v1/models` errors on an empty cache),
    which any mlx user already has.
- No third party Swift dependencies. Hearth builds against Apple system
  frameworks only (Foundation, AppKit, IOKit, Network, ServiceManagement, and
  UserNotifications), which keeps the dependency surface, and the licensing
  surface, empty.

## Install and build

Hearth is a Swift Package Manager project.

Build and run from a checkout:

```
swift build -c release
swift run Hearth
```

`swift run Hearth` launches the agent directly. A flame icon appears in the
menubar; there is no Dock icon. Running this way is fine for development, but
two features only work from a packaged, signed app: autostart at login
(SMAppService) and local Notification Center alerts. Run unbundled, both degrade
gracefully and the menubar reflects the real state rather than pretending.

To assemble a `.app` bundle:

```
./scripts/package-app.sh
open dist/Hearth.app
```

To actually run it day to day before there is a notarized release, install a
local, ad-hoc signed copy to `/Applications`:

```
make install
open /Applications/Hearth.app
```

Ad-hoc signing gives the bundle a stable local code identity, which is what the
login item and Notification Center alerts want, without needing a Developer ID.
It is for your own machine, not distribution. To remove a local install (the app,
config, logs, and state), run `make uninstall`.

Hearth ships as a Developer ID signed and notarized build, not through the Mac
App Store. This is not a preference; the App Store requires the App Sandbox, and
the sandbox forbids a process from spawning and supervising another process,
which is the entire job. So the distribution path is Developer ID plus
notarization with the Hardened Runtime on and the App Sandbox off. See
[Development](docs/development.md) for the signing pipeline.

### Homebrew cask

The signed release installs with Homebrew:

```
brew install --cask adamskijow/tap/hearth
```

The cask lives at `Casks/hearth.rb` and is mirrored to the `adamskijow/homebrew-tap`
tap. The release pipeline bumps its `version` and `sha256` to match each published
DMG.

## Configure

There are two ways to configure Hearth, and they edit the same file. Open
**Preferences** from the menubar (or press Cmd-comma) for a form covering the
runner, notifications, the control endpoint, log rotation, and the timing knobs.
Or edit the JSON directly at:

```
~/Library/Application Support/Hearth/config.json
```

Either way, changes apply **without a restart**: the Preferences window's Save
reloads live, and after editing the file by hand you choose "Reload Config" from
the menu (or send the agent SIGHUP). Reloading briefly restarts the runner.

On first launch, if the file is missing, Hearth writes a starter template with
the runner binary auto detected (it probes Homebrew, the Ollama.app install, and
your PATH), so first run does not fail on a wrong path. If the runner still is not
found, the menubar says so and offers a one-click fix. Every key is optional;
anything you leave out falls back to its default. A malformed file is
flagged loudly and your running setup is kept rather than silently reverted. To
point Hearth at a config somewhere else, set the `HEARTH_CONFIG` environment
variable to that path.

The keys most people touch:

- `runner` and `mode`: which runner (`ollama`, `lmstudio`, or `mlx`) and whether
  Hearth launches it (`managed`) or only watches one you started (`attached`).
- `ollamaBinaryPath` (or `lmStudioBinaryPath` / `mlxBinaryPath`): where the runner
  binary is, if it is not at the default.
- `host` and `port`: the address the runner serves on (default `127.0.0.1:11434`;
  set `host` to `0.0.0.0` to reach it from another machine on your LAN, see
  [Troubleshooting](#troubleshooting)).
- `ntfyTopic`: a long, unguessable ntfy topic for phone alerts.
- `controlEnabled` and `controlToken`: turn on the HTTP control endpoint and set
  the bearer token every request must carry.
- `maintenanceRestartHours`: cycle a healthy runner this often (for example `24`)
  to clear memory creep. Off by default.
- `runnerEnv`: extra environment variables for a managed runner (for example
  `OLLAMA_LOAD_TIMEOUT` or `OLLAMA_KEEP_ALIVE`), set from the **Set Env** button in
  Preferences or as a config map. Hearth sets `OLLAMA_HOST` itself from `host`/`port`.

Everything else has a sensible default: the probe and backoff timing, the
crash-loop brake, the pressure-alert thresholds, log rotation, and the reboot
escalation. The [configuration reference](docs/configuration.md) lists every key,
its type, and its default.

A typical config:

```json
{
  "runner": "ollama",
  "mode": "managed",
  "host": "127.0.0.1",
  "port": 11434,
  "ntfyTopic": "my-private-hearth-topic-7f3a",
  "controlEnabled": true,
  "controlHost": "127.0.0.1",
  "controlPort": 11435,
  "controlToken": "a-long-unguessable-secret"
}
```

To get phone notifications, set `ntfyTopic` to a long, unguessable string and
subscribe to that same topic in the ntfy app on your phone. Anyone who knows a
public ntfy topic can read it, so treat the topic name like a secret.

## How it works

Hearth's default is managed mode. It spawns the runner child itself and owns it,
setting the child's environment at launch. Because Hearth defines the child's
environment, `OLLAMA_HOST` is pinned to your configured host and port by
construction, which is what sidesteps the launchd env trap.

The runner is spawned in its own process group. That matters because a runner
forks helpers (an Ollama serve forks a separate `llama-server` that holds GPU and
unified memory), and on teardown or restart Hearth kills the whole group, so a
helper is never orphaned to leak memory across a restart loop. This is verified
against a real Ollama in [VALIDATION-REPORT.md](VALIDATION-REPORT.md).

That covers every exit Hearth gets to observe. The one it cannot observe is its
own hard death: if Hearth is SIGKILLed, it never runs teardown and the group it
spawned is left behind. To close that, Hearth records the runner's PID, process
group, and start time to disk on every spawn, and on the next launch it sweeps
any recorded group that is still alive before starting fresh. The start time is
the safety check: a recycled PID belonging to a different process has a different
start time, so Hearth never kills a bystander.

In attached mode, Hearth does not spawn anything. It monitors a runner that
something else started, by probing its readiness endpoint. It still holds the
power assertion and notifies on transitions, but it never spawns or kills a
process it does not own. Attached mode is the reliable way to use LM Studio,
whose `lms server start` may hand the server off to a background service rather
than staying in the foreground.

Health has two parts. Liveness asks whether the child process is still alive.
Readiness asks whether the runner's version endpoint actually answers within the
probe timeout. Readiness is the important half: it catches the alive but wedged
runner that a liveness check alone would call healthy, and treats it as down. (In
attached mode there is no child to inspect, so readiness is the whole signal.)

When the runner stops serving, whether it crashed or wedged, Hearth restarts it
(in managed mode) on an exponential backoff capped at `maxBackoffSeconds`. If
failures keep coming, specifically `crashLoopThreshold` failures within
`crashLoopWindowSeconds`, Hearth decides it is in a crash loop. It stops
thrashing, enters a failing state, and retries slowly on
`failingProbeIntervalSeconds` instead of hammering the machine. It keeps probing,
so if the underlying problem clears, it recovers on its own.

<p align="center">
  <img src="assets/state-machine.svg" alt="The supervisor state machine: Stopped to Starting to Healthy, with a failure cycle through Down, Restarting, and Failing" width="820">
</p>

Hearth classifies how the child exited from its exit status and recent stderr,
distinguishing a clean stop from an ordinary crash from an out of memory kill.
The out of memory case matters on a unified memory Mac, where an oversized model
can take down the whole box rather than failing a single request.

While it intends to keep the runner up, Hearth holds an IOKit power assertion
(`PreventUserIdleSystemSleep`) so the Mac does not idle sleep out from under a
service that is supposed to be available. It releases the assertion when you stop
supervision. You can confirm the assertion with `pmset -g assertions`.

Notifications fire on the transitions that matter: going down, recovering, and
entering the failing state. There are three delivery paths. Local Notification
Center alerts for when you are at the machine, and ntfy HTTP posts for when you
are not, so a Mac in a closet can still reach your phone. Set `webhookURL` and
Hearth also POSTs a small JSON status body (`level`, `title`, `body`, `event`,
`timestamp`) to your own endpoint on each event, to wire into your own automation.
All three carry only Hearth's own short status, never runner content.

The menubar shows the current status, the models the runner currently holds
resident (from its own API, surfaced for awareness only, never chosen by Hearth),
uptime of the current healthy streak, and the reason for the last restart. It
also shows a coarse system readout: the thermal state (throttling risk), the
fraction of physical memory in use (out of memory risk), and the runner's
resident memory. These come from public APIs only, no root, and are
observability, not inference. The actions are Start, Stop, Restart, and Open
Logs. The child's stdout and stderr are captured to
`~/Library/Logs/Hearth/runner.log`.

Beyond reacting to failures, a few opt-in settings address slow degradation.
`maintenanceRestartHours` cycles a healthy runner on an interval (for example `24`)
to clear the memory creep that slows a long-running Ollama, quietly, with no
"recovered" alert. `restartOnBinaryChange` adopts a new binary after a
`brew upgrade` instead of serving the old one forever (managed mode). And the same
memory and thermal samples behind the menubar readout can alert: when system memory
crosses `memoryAlertPercent` (default 90) or thermals go serious, Hearth sends a
heads-up, and an all-clear when it eases, before pressure becomes a crash.

## Remote control

With `controlEnabled` and a `controlToken` set, Hearth runs a small HTTP control
endpoint so a phone can check status and start, stop, or restart the runner, not
just receive notifications. Every request must carry the token as a bearer
header.

```
# status
curl -H "Authorization: Bearer $TOKEN" http://HOST:11435/status

# control
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/restart
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/stop
curl -X POST -H "Authorization: Bearer $TOKEN" http://HOST:11435/start
```

`/status` returns a compact JSON document with the phase, resident models,
uptime, restart count, last restart reason, and the system metrics (thermal
state, memory used percent, runner resident bytes). `/metrics` returns the same
data as a Prometheus text exposition (also behind the token), so you can scrape
Hearth into Grafana or Uptime Kuma; and the unauthenticated `/healthz` returns
`200` when Hearth is up, for an uptime monitor. The control endpoint is a control
surface, not a public API: bind it to localhost or a private interface (a
Tailscale address is ideal) and keep it behind a VPN. It refuses to start without
a token, and rejects any request whose bearer token does not match.

Opening the control URL in a browser (`http://HOST:11435/`) serves a small status
page for phones: paste your token once (it is stored in that browser only, never
in the URL) and it polls `/status` and shows the phase, uptime, and metrics. The
page itself is unauthenticated but reveals nothing; the status fetch it makes
carries the token.

When Hearth detects a Tailscale address on the machine (an interface in the
100.64.0.0/10 range), the menubar shows a "Phone access" line with the full
control URL to use from your phone. Hearth only reads the interface list; it does
not configure Tailscale.

### Local status and logs

From the same machine, two terminal subcommands give a quick read without the
menubar or a curl invocation:

```
hearth setup               # turnkey: detect runner, install login agent, wait for ready
hearth status [--json]     # phase, uptime, restarts, metrics, resident models (--json for agents)
hearth logs -n 100         # last 100 lines of the runner log
hearth logs -f             # follow the runner log
hearth events              # Hearth's own event history (down, restart, recovered)
hearth metrics             # memory and thermal history over the retained window
hearth doctor              # check the config and environment for problems
hearth wait-ready [-t S]   # block until the runner answers, then exit 0 (1 on timeout)
hearth install-agent       # install a login agent that keeps Hearth running (no sudo)
hearth uninstall-agent     # remove that login agent
```

`hearth status` reads the config (at `HEARTH_CONFIG` or the standard location)
and queries the control endpoint when it is enabled, printing the full picture.
With the control endpoint off it falls back to a reduced report: whether a
supervised runner is recorded and alive, and whether anything is serving on the
runner's port.

Hearth records its own decisions (became healthy, down with the cause, restart
scheduled, recovered, crash loop) to a small line-capped `events.log` next to the
runner log. Unlike the in-memory recent-activity list, this survives a restart,
so `hearth events`, the menu's Recent activity, and the tail shown by
`hearth status` all answer "why did it restart last night." The runner log
(`hearth logs`) is the runner's own stdout and stderr; the event log is Hearth's
view of it.

`hearth doctor` is a preflight check. It validates the config (port ranges, an
unknown runner or mode, a control endpoint with no token, a control port that
collides with the runner port, backoff timings that cannot grow) and the
environment (the runner binary exists and is executable, the runner port is free
for a managed runner or already serving for an attached one, the log directory is
writable), then prints each result and exits non-zero if anything is an error.

## Troubleshooting

Run `hearth doctor` first; it catches most of these and tells you which. The menu
also shows a "config issues" line when it finds any.

- **The menubar flame never goes green / "runner binary not found."** Hearth is
  looking for the runner at the default path and not finding it. Set
  `ollamaBinaryPath` (or `lmStudioBinaryPath` / `mlxBinaryPath`) to the output of
  `which ollama`, in Preferences or the config. `hearth doctor` reports the path
  it tried.
- **LM Studio keeps restarting (down, restarting, down).** Managed mode does not
  work with LM Studio: `lms server start` exits immediately. Set `mode` to
  `attached` and start LM Studio's server yourself; Hearth will watch it.
- **mlx_lm never reaches healthy.** `mlx_lm.server`'s `/v1/models` errors until at
  least one MLX model is in your HuggingFace cache. Download any model once.
- **Login item or notifications do nothing.** Those need the packaged, signed app
  (`make install` or the cask), not `swift run Hearth`. Unbundled, they degrade
  gracefully and the menu says so.
- **`hearth status` says the control endpoint is unreachable.** Enable it
  (`controlEnabled`, with a `controlToken`), and check `controlHost`/`controlPort`.
  Bind it to localhost or a Tailscale address, never a public interface.
- **Another computer can't reach the runner (connection refused).** By default
  Ollama binds to `127.0.0.1`, so it is reachable only from the Mac it runs on. Set
  `host` to `0.0.0.0` to open it to your LAN: managed Hearth then launches the runner
  bound correctly, with no `launchctl setenv OLLAMA_HOST` ritual. Open the firewall
  for the port, then connect from the other machine to `http://<this-mac-lan-ip>:11434`.
  `hearth doctor` prints the exact URL and the firewall reminder, and the menu shows
  a "Reachable at" line once it is open. For access beyond your LAN, use Tailscale
  rather than exposing the port. To carry hand-tuned runner settings
  (`OLLAMA_LOAD_TIMEOUT` and the like) along with the bind change, set them in
  `runnerEnv` so they live in the config instead of a launchd plist.
- **A stray `ollama serve` is running after a restart.** Hearth records the
  process group it owns and sweeps it on the next launch. If you deleted
  `runner-state.json` by hand, that record is gone; kill the stray once and let
  Hearth own the next one.
- **The runner keeps restarting and the state churns (managed mode).** Something
  else is also managing the runner and fighting Hearth over it, most often
  `brew services`. `hearth doctor` and the menu flag this; run
  `brew services stop ollama` so Hearth is the sole supervisor. (Two Hearths can
  also collide; the single-instance guard handles that, but a non-Hearth manager
  needs stopping.)

## Running headless

The menubar agent needs a logged in desktop session. For a Mac where nobody logs
in, Hearth has a headless mode that runs supervision with no GUI: no menubar and
no local Notification Center (there is no session to show it), but ntfy still
reaches your phone, and the control endpoint and the power assertion work the
same.

```
hearth --headless          # or set HEARTH_HEADLESS=1
```

### Keep it running at login (one command)

The easy way to run Hearth headless and keep it alive is a per-user login agent,
installed in one step (no sudo):

```
hearth install-agent
```

This writes `~/Library/LaunchAgents/com.hearth.headless.plist` pointing at the
Hearth binary you ran it from and your config, then loads it with `launchctl`.
Hearth now starts headless at login and is kept alive. Remove it any time with
`hearth uninstall-agent`.

It is safe to run even if the menubar app also launches at login: the
single-instance guard means whichever starts first supervises and the other stands
by, so they never fight. This is the recommended setup for an app that depends on a
local runner staying up. Such an app does not integrate with Hearth's API; it
depends on the runner directly and gates its own startup on the runner answering:

```
hearth wait-ready && my-app   # start once the runner actually answers
```

The full contract (what to do, what not, graceful degradation, the Hob example) is
in [Integrating with Hearth](docs/integrating.md).

### Before anyone logs in (root daemon)

A login agent only runs once you are logged in. To run Hearth before any login (a
Mac in a closet that reboots unattended), install it as a root LaunchDaemon. The
files are in `deploy/` and the installer is `scripts/install-daemon.sh`. It
modifies your system (writes to `/usr/local/bin`, `/etc/hearth`, and
`/Library/LaunchDaemons`), so read it first and run it with sudo:

```
swift build -c release
sudo ./scripts/install-daemon.sh
# edit /etc/hearth/config.json (set your tokens), then:
sudo launchctl kickstart -k system/com.hearth.daemon
```

Remove it with `sudo ./scripts/uninstall-daemon.sh`. In daemon mode Hearth runs
as root, so its config lives at `/etc/hearth/config.json` (pointed to by the
plist's `HEARTH_CONFIG`) and its logs at `/var/log/hearth.out.log` and
`/var/log/hearth.err.log`. After editing the config, apply it without restarting
by sending SIGHUP: `sudo launchctl kill HUP system/com.hearth.daemon`.

## Recovering a wedge a restart cannot

Killing and respawning the runner clears a process-level wedge. Some hangs are at
the driver or GPU level and survive a process restart; only a reboot of the Mac
clears them (see [Known limitations](docs/limitations.md)). On a headless box you would otherwise have to
notice and reboot it by hand. The recovery ladder closes that gap as an opt-in
last resort:

```
probe readiness
  wedged?           -> kill and respawn the runner group   (clears most wedges)
  still wedged long
  after restarts
  stopped helping?  -> reboot the Mac -> comes back, respawns the runner clean
```

Enable it in the config. It is off by default and needs Hearth running as root
(the headless daemon above), because rebooting takes privileges:

```json
{ "rebootOnWedge": true }
```

The policy is deliberately paranoid, because an auto-reboot done wrong is a boot
loop:

- Off by default; nothing reboots unless you opt in.
- Only after the runner was actually healthy this session. A wrong binary path or
  a bad config never triggers a reboot, only a runner that was serving and then
  wedged past what a restart can fix.
- Only after a sustained failing streak (`rebootEscalateAfterSeconds`, default ten
  minutes), so a brief blip never reboots.
- Loop-protected. The reboot history is persisted across the reboots themselves;
  if a reboot did not help (still wedged sooner than `rebootMinIntervalSeconds`)
  or the daily cap (`rebootMaxPerDay`) is reached, Hearth stops and notifies you
  rather than rebooting again.
- Loud. ntfy fires before the reboot, and again if it gives up.

A reboot cannot fix a hardware or thermal fault, so the give-up-and-notify path is
the honest floor: if even a reboot does not restore the runner, a human needs to
look.

## Security and exposing the runner

Hearth runs unsandboxed, by necessity: supervising another process is exactly what
the App Sandbox forbids, so it ships with the App Sandbox off and the Hardened
Runtime on, as a Developer ID notarized build. It spawns and owns the runner child
and reads that runner's local API to judge health. It sends only short status text
to notifiers; no prompts, model data, or runner content ever leave the machine.

It is also conservative about putting the runner on the network. By default the
runner listens on `127.0.0.1`, reachable only from this Mac. For another machine on
a network you trust (a home LAN behind a firewall), setting `host` to `0.0.0.0` is
the simple path: `hearth doctor` reports the URL to use and the firewall caveat (see
[Troubleshooting](#troubleshooting)). What you should not do is expose it raw to an
untrusted network or the internet, since the runner has no authentication of its
own. For that, keep it on `127.0.0.1` and put an authenticating reverse proxy in
front, bound to a private (Tailscale) address; proxying inference traffic is a job
for a battle-tested proxy, not something Hearth should reimplement. The
[reverse-proxy guide](docs/reverse-proxy.md) has Caddy and nginx examples, plus the
unauthenticated `/healthz` route for uptime monitors. Hearth's own control endpoint
is separate: off by default, a bearer token required when on, bound to a private
interface, and only for supervision (status, start, stop, restart), never inference.

## Architecture

The code is split into a logic half and a presentation half, with a hard line
between them.

`SupervisorCore` is a library that holds all the decision logic and imports no
AppKit and no SwiftUI. Time, process control, HTTP, power, and notifications all
sit behind protocols, so the whole thing is unit testable with fakes and never
touches real I/O in a test. The heart is an explicit restart state machine and a
pure exit classifier; both take the current time as an argument rather than
reading a clock, so their behavior is fully determined by their inputs. The
runner specifics (Ollama, LM Studio, mlx_lm), the control endpoint's routing and
auth, and the metrics and tailnet helpers also live here as pure, tested code.

`Hearth` is the executable: the menubar agent that wires the core to real process
spawning (`posix_spawn` in a dedicated process group), URLSession, IOKit, the
Network framework, SMAppService, and UserNotifications, and renders the published
state.

## Roadmap

Near term intentions:

- A tokens per second readout, alongside the existing thermal and memory metrics.
- Full Tailscale auto configuration (tailnet address detection is already done).
- A first class authenticating proxy (today Hearth ships a documented Caddy
  config at `deploy/Caddyfile.example`).
- More runners behind the `Runner` protocol as people want them.

## Contributing

Contributions are welcome. The project values the split between logic and
presentation: decision logic belongs in `SupervisorCore`, behind protocols, with
tests, and never imports AppKit or SwiftUI. Anything runner specific belongs
inside the runner implementation, not leaked into the engine or the UI. Please
keep new dependencies out unless there is a strong reason, and prefer permissive
licenses if one is unavoidable. Run `make test` before sending a change. Running
the full test suite and cutting a release are covered in
[docs/development.md](docs/development.md).

## License

Hearth is released under the MIT License. See the [LICENSE](LICENSE) file for the
full text. There are no third party dependencies, so there are no additional
license obligations to carry.
