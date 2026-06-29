<p align="center">
  <img src="assets/hearth-banner.svg" alt="Hearth: keeps your local LLM runner alive on a headless Mac" width="100%">
</p>

# Hearth

Hearth is a background supervisor that keeps a local LLM runner (Ollama, with LM
Studio and mlx_lm support) alive and serving on a headless Mac.

It is an availability layer, not an inference layer. Hearth watches the runner,
restarts it when it dies or wedges, keeps the Mac awake while it is meant to be
serving, and tells you when something goes wrong. It does not do inference. It
does not pick models, set context length, write prompts, or do RAG or chat. It
does not replace Ollama or LM Studio. The runner is an opaque child process that
Hearth owns and supervises; Hearth reads the runner's API and logs only to judge
whether it is healthy.

## Why this exists

If you run a local model server on a Mac you leave in a closet, the usual fix is a
launchd plist (or `brew services`) with `KeepAlive`, which relaunches the runner
when the process exits. That handles a clean crash. It does not handle the failure
that actually wastes your afternoon: the runner is still running, but no longer
answering.

That "alive but wedged" state is common and well reported. The model runner hangs
after a few requests with no error and has to be killed by hand
([ollama#6616](https://github.com/ollama/ollama/issues/6616)); the GPU stops
responding and "the service needs to be rebooted"
([Framework](https://community.frame.work/t/ollama-model-runner-unexpectedly-stopped-gpu-hang/76220));
or Ollama silently reverts to CPU and spins for hours without ever replying
([ollama#8594](https://github.com/ollama/ollama/issues/8594)). The process is up
the whole time, so a **liveness** check ("is the PID there?") is satisfied and
launchd does nothing.

Hearth probes **readiness** instead ("does the API actually answer in time?"), so
it catches the wedge, not just the crash. Put simply: **launchd restarts the
runner when it dies; Hearth also restarts it when it wedges.**

Two more things quietly break the "always available" promise, and Hearth handles
both. The Mac goes to sleep and stops serving, so Hearth holds an IOKit power
assertion. And the `OLLAMA_HOST` env trap, where a launchd-started daemon does not
inherit the shell environment you expected and ends up on the wrong address or
only on localhost, is sidestepped because Hearth sets the runner's environment at
spawn, so the listen address is correct by construction.

Hearth exists to make a local runner behave like a real, always on service on a
machine nobody is sitting at.

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
notarization with the Hardened Runtime on and the App Sandbox off. See Releasing
below for the signing pipeline.

### Homebrew cask

A signed release can be installed with Homebrew once published:

```
brew install --cask adamskijow/tap/hearth
```

The cask lives at `Casks/hearth.rb`. It is a template until the first signed
release is attached to a GitHub release; the version and sha256 are filled in by
the release pipeline.

## Configure

There are two ways to configure Hearth, and they edit the same file. Open
**Preferences** from the menubar (or press Cmd-comma) for a form covering the
runner, notifications, the control endpoint, log rotation, and the timing knobs.
Every key, its type, and its default is listed in the
[configuration reference](docs/configuration.md). Or edit the JSON directly at:

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
anything you leave out falls back to the default below. A malformed file is
flagged loudly and your running setup is kept rather than silently reverted. To
point Hearth at a config somewhere else, set the `HEARTH_CONFIG` environment
variable to that path.

Keys, defaults, and what they do:

Runner

- `runner` (default `"ollama"`): which runner to supervise, `"ollama"`,
  `"lmstudio"`, or `"mlx"`.
- `mode` (default `"managed"`): `"managed"` means Hearth spawns and owns the
  runner; `"attached"` means it only monitors an already running one (below).
- `ollamaBinaryPath` (default `"/opt/homebrew/bin/ollama"`): the Ollama binary,
  when `runner` is `ollama`.
- `lmStudioBinaryPath` (default `"/usr/local/bin/lms"`): the LM Studio CLI, when
  `runner` is `lmstudio`.
- `mlxBinaryPath` (default `"/opt/homebrew/bin/mlx_lm.server"`): the mlx_lm
  server, when `runner` is `mlx`.
- `host` (default `"127.0.0.1"`): the address the runner listens on. For Ollama
  this is set via `OLLAMA_HOST` at spawn. Use `"0.0.0.0"` to listen on all
  interfaces (see the security note before you do).
- `port` (default `11434`): the listen port. LM Studio's default is `1234`.

Health and restart policy

- `probeTimeoutSeconds` (default `2`): how long a readiness request may take
  before it counts as timed out. A timeout is the signature of a wedged runner.
- `probeIntervalSeconds` (default `5`): how often to check health while healthy.
  This is also roughly how fast a death is detected.
- `startupGraceSeconds` (default `30`): after a spawn, how long "alive but not
  answering yet" is treated as normal warm up rather than a failure.
- `startupProbeIntervalSeconds` (default `1`): how often to check while starting
  or restarting, before the runner is ready.
- `initialBackoffSeconds` (default `1`): the first restart backoff.
- `backoffMultiplier` (default `2`): each consecutive failure multiplies the
  backoff by this.
- `maxBackoffSeconds` (default `60`): the backoff never grows past this.
- `crashLoopThreshold` (default `5`): this many failures inside the window trips
  the failing state.
- `crashLoopWindowSeconds` (default `60`): the sliding window over which failures
  are counted for crash loop detection.
- `failingProbeIntervalSeconds` (default `30`): the slow retry cadence used once
  failing, instead of fast backoff.

Notifications

- `ntfyTopic` (default `null`): an ntfy topic to post notifications to, so a
  headless Mac can reach your phone. `null` disables ntfy.
- `ntfyServer` (default `"https://ntfy.sh"`): the ntfy server base URL.
- `localNotifications` (default `true`): post to the local Notification Center
  when running as a bundled app.

Remote control

- `controlEnabled` (default `false`): enable the HTTP control endpoint.
- `controlHost` (default `"127.0.0.1"`): the address the control endpoint binds
  to. Use your Tailscale or private interface address to reach it from a phone.
- `controlPort` (default `11435`): the control endpoint port.
- `controlToken` (default `null`): the bearer token every control request must
  carry. The endpoint refuses to start without one.

Runner log

- `logMaxBytes` (default `5000000`): rotate the runner log once it reaches this
  many bytes. Zero disables rotation.
- `logKeepFiles` (default `3`): how many rotated logs to keep (`runner.log.1` ...
  `runner.log.N`); the oldest is deleted.

A complete example:

```json
{
  "runner": "ollama",
  "mode": "managed",
  "ollamaBinaryPath": "/opt/homebrew/bin/ollama",
  "host": "127.0.0.1",
  "port": 11434,
  "probeTimeoutSeconds": 2,
  "probeIntervalSeconds": 5,
  "startupGraceSeconds": 30,
  "startupProbeIntervalSeconds": 1,
  "initialBackoffSeconds": 1,
  "backoffMultiplier": 2,
  "maxBackoffSeconds": 60,
  "crashLoopThreshold": 5,
  "crashLoopWindowSeconds": 60,
  "failingProbeIntervalSeconds": 30,
  "ntfyTopic": "my-private-hearth-topic-7f3a",
  "ntfyServer": "https://ntfy.sh",
  "localNotifications": true,
  "controlEnabled": true,
  "controlHost": "127.0.0.1",
  "controlPort": 11435,
  "controlToken": "a-long-unguessable-secret",
  "logMaxBytes": 5000000,
  "logKeepFiles": 3
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
entering the failing state. There are two delivery paths. Local Notification
Center alerts for when you are at the machine, and ntfy HTTP posts for when you
are not, so a Mac in a closet can still reach your phone.

The menubar shows the current status, the models the runner currently holds
resident (from its own API, surfaced for awareness only, never chosen by Hearth),
uptime of the current healthy streak, and the reason for the last restart. It
also shows a coarse system readout: the thermal state (throttling risk), the
fraction of physical memory in use (out of memory risk), and the runner's
resident memory. These come from public APIs only, no root, and are
observability, not inference. The actions are Start, Stop, Restart, and Open
Logs. The child's stdout and stderr are captured to
`~/Library/Logs/Hearth/runner.log`.

## Keeping a 24/7 runner fresh

Two opt-in features address what degrades a runner left up for days, not what
crashes it.

A widely reported problem with a long-running Ollama is gradual memory creep and
VRAM fragmentation: over a day or two, response times slide from a couple of
seconds to ten or more, and the documented fix everywhere is "restart it daily."
Hearth can do that for you. Set `maintenanceRestartHours` (for example `24`) and
it cycles a healthy runner on that interval, clearing the creep. It is a clean
restart counted off the runner's healthy uptime, so a reactive restart resets the
clock too, and the return to healthy is quiet (no "recovered" alert for a routine
cycle). Off by default.

Hearth already samples the thermal state and memory pressure for the menubar; it
can also alert on them. When system memory crosses `memoryAlertPercent` (default
90), which on a unified-memory Mac is the precursor to macOS killing the runner as
its biggest memory user, or when thermals go serious or critical
(`thermalAlerts`), Hearth sends a heads-up (and an all-clear when it eases) so you
learn about pressure before it turns into a crash. On by default; both reuse the
metrics already collected.

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
state, memory used percent, runner resident bytes). The control endpoint is a
control surface, not a public API: bind it to localhost or a private interface (a
Tailscale address is ideal) and keep it behind a VPN. It refuses to start without
a token, and rejects any request whose bearer token does not match.

When Hearth detects a Tailscale address on the machine (an interface in the
100.64.0.0/10 range), the menubar shows a "Phone access" line with the full
control URL to use from your phone. Hearth only reads the interface list; it does
not configure Tailscale.

### Local status and logs

From the same machine, two terminal subcommands give a quick read without the
menubar or a curl invocation:

```
hearth status              # phase, uptime, restarts, metrics, resident models
hearth logs -n 100         # last 100 lines of the runner log
hearth logs -f             # follow the runner log
hearth events              # Hearth's own event history (down, restart, recovered)
hearth doctor              # check the config and environment for problems
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

## Running headless

The menubar agent needs a logged in desktop session. For a Mac where nobody logs
in, Hearth has a headless mode that runs supervision with no GUI: no menubar and
no local Notification Center (there is no session to show it), but ntfy still
reaches your phone, and the control endpoint and the power assertion work the
same.

```
hearth --headless          # or set HEARTH_HEADLESS=1
```

To run it before anyone logs in, install it as a root LaunchDaemon. The files are
in `deploy/` and the installer is `scripts/install-daemon.sh`. It modifies your
system (writes to `/usr/local/bin`, `/etc/hearth`, and
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
clears them (see Known limitations). On a headless box you would otherwise have to
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

## Exposing the runner

Hearth keeps the runner alive but does not put it on the network. If you want to
reach the runner's API from another machine, do not set the runner's `host` to
`0.0.0.0` and expose it raw. Keep it on `127.0.0.1` and put an authenticating
reverse proxy in front, bound to a private (Tailscale) address. Proxying
inference traffic is a job for a battle tested proxy, not something Hearth should
reimplement. The [reverse-proxy guide](docs/reverse-proxy.md) has Caddy and nginx
examples for the runner and the control endpoint, plus the unauthenticated
`/healthz` route for uptime monitors. Hearth's own control endpoint is separate
and is only for supervision (status, start, stop, restart), never inference.

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

## Testing

`SupervisorCore` is covered by a Swift Testing suite driven entirely by fakes for
the clock, process control, and HTTP. There is no real runner and no real
`sleep`; the fake clock is advanced by hand. The suite covers readiness catching
a hung but alive runner, exponential backoff timing, a crash loop entering the
failing state without thrashing, recovery back to healthy, out of memory versus
crash classification, attached mode never spawning or killing, the runners' spec
and parsing (including a real Ollama `/api/ps` capture), the pre-spawn process
group sweep, the hard-crash sweep decision, log rotation decisions, the control
endpoint's routing and auth, the metrics formatting, tailnet address recognition,
runner binary location ordering, config resolution (the first-run, clean, and
parse-failure paths), the status line wording for every phase, the readiness
mapping from each HTTP outcome, and the exit and down-reason labels.

For end to end checks against a live server, `scripts/validate-real.sh` drives the
real agent against a real `ollama serve` and proves the lifecycle scenarios
(cold start, external kill, the SIGSTOP wedge, process group teardown with no
orphans, attached mode, and hard-crash orphan recovery), exiting non-zero on any
failure. It needs a real Ollama; its findings and the fix it drove are written up
in [VALIDATION-REPORT.md](VALIDATION-REPORT.md).

Run the tests with:

```
make test
```

or directly:

```
./scripts/test.sh
```

The wrapper exists because the tests use Swift Testing, and on a Mac with only
the Command Line Tools installed (the common state on a headless box) the Swift
Testing framework is not on the default search path. The script detects the right
directory for both the Command Line Tools and full Xcode layouts and passes it.
On a machine with full Xcode, a plain `swift test` also works.

The gate runs in two places, both through `scripts/ci.sh`: locally via the
pre-push hook, and on GitHub Actions (free for public repositories) for every push
and pull request (`.github/workflows/ci.yml`). `make ci` (or `./scripts/ci.sh`)
builds debug and release, runs the unit suite, and lints (an SPDX header on every
Swift source, and the no em dash rule). Install the pre-push hook once with
`make hooks`, which points `core.hooksPath` at the in-repo `scripts/hooks`, and
that gate runs before every push; bypass a single push with `git push
--no-verify`. Pass `--smoke` or `--real` to `scripts/ci.sh` to also run the
desktop and Ollama gates described below.

### Trying it without a runner

You can exercise the whole agent without installing Ollama or LM Studio, using a
small stand in runner that answers the endpoints Hearth probes:

```
./scripts/smoke-test.sh
```

This builds Hearth, points it at `scripts/fake-runner.py` through a throwaway
config, and checks the acceptance behavior end to end: the agent starts and owns
the child, holds the power assertion (`pmset`), restarts the child when it is
killed externally, drives a restart through the control endpoint (with token auth
checked), and releases the assertion and kills the child on a clean shutdown. It
launches the real menubar agent, so it needs a logged in desktop session; it is a
local helper, not a CI step.

## Releasing

`scripts/release.sh` builds, Developer ID signs (Hardened Runtime on, App Sandbox
off), notarizes, and staples `Hearth.app`, then packages it two ways: a
drag-to-install DMG (`scripts/make-dmg.sh`, the app plus an Applications shortcut)
and a zip, notarizing and stapling the DMG as well. It prints the sha256 of each.
It needs a signing identity and notarization credentials, either a stored
notarytool profile:

```
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_PROFILE="HearthNotary"   # from xcrun notarytool store-credentials
./scripts/release.sh
```

or an App Store Connect API key passed directly, which works in a non-interactive
shell where storing a keychain profile is blocked:

```
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_KEY="$HOME/path/AuthKey_XXXX.p8"
export HEARTH_NOTARY_KEY_ID="XXXX"            # the XXXX in the filename
export HEARTH_NOTARY_ISSUER="<issuer-uuid>"   # App Store Connect issuer ID
./scripts/release.sh
```

Releasing is local: run it on your Mac, attach the DMG (and zip) to a GitHub
release, then set `Casks/hearth.rb` `version` and `sha256` to the DMG's. Once
published from a tap, install with `brew install --cask adamskijow/tap/hearth`.
For a quick local install without a release, `make install` ad-hoc signs and
copies the app to `/Applications`.

## Known limitations

These are stated up front on purpose.

- Restarting the runner clears a process-level wedge, not a driver- or GPU-level
  one. Some hangs need a full reboot, not a process restart: people report that
  "stopping and restarting ollama doesn't resolve the issue, only a full restart
  works" ([ollama#8594](https://github.com/ollama/ollama/issues/8594)). Hearth
  kills and respawns the runner's process group, which recovers the common cases
  (a hung serve, a deadlocked model load, a wedged child); a GPU stuck at the
  driver level is beyond what any process supervisor can fix. On Apple Silicon and
  Metal a respawn clears more of these than on the discrete-GPU setups in those
  reports, but it is not a cure-all. For a headless daemon, the opt-in reboot
  escalation ("Recovering a wedge a restart cannot") can automate the reboot that
  does clear it, with a loop guard and a give-up-and-notify floor.
- Validated against a real Ollama 0.30.11 (see
  [VALIDATION-REPORT.md](VALIDATION-REPORT.md)): cold start, external kill, the
  alive-but-wedged case via SIGSTOP, clean process group teardown with no
  orphaned `llama-server`, attached mode, and hard-crash orphan recovery (a
  SIGKILLed Hearth's leaked runner group is swept on the next launch). LM Studio
  and mlx_lm are covered by unit tests against captured payloads but have not yet
  been exercised against live servers.
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
- LM Studio's managed launch is best effort, because `lms server start` may
  background the server rather than staying in the foreground. Attached mode is
  the reliable path for LM Studio.
- The control endpoint is unauthenticated beyond a shared bearer token and is
  meant to live behind a VPN, not on the open internet.

## Security note

Hearth runs unsandboxed, by necessity. Supervising another process is exactly
what the App Sandbox forbids, so Hearth ships with the App Sandbox off and the
Hardened Runtime on, distributed as a Developer ID notarized build. It spawns and
owns a child process, the runner, and reads that runner's local API to judge
health.

Hearth never exposes the runner beyond what you configure. By default the runner
listens on `127.0.0.1`, reachable only from the same machine. If you set `host`
to `0.0.0.0` you are choosing to expose the runner on your network, and securing
that (a firewall, a VPN such as Tailscale, or an authenticating reverse proxy) is
up to you. The control endpoint is off by default; when on, it requires a bearer
token and should be bound to a private interface. Hearth sends only short status
text to notifiers; no prompts, model data, or runner content leave the machine.

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
licenses if one is unavoidable. Run `make test` before sending a change.

## License

Hearth is released under the MIT License. See the [LICENSE](LICENSE) file for the
full text. There are no third party dependencies, so there are no additional
license obligations to carry.
