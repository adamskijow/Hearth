# Hearth

Hearth is a background supervisor that keeps a local LLM runner alive and serving
on a headless Mac.

It is an availability layer, not an inference layer. Hearth watches the runner,
restarts it when it dies or wedges, keeps the Mac awake while it is meant to be
serving, and tells you when something goes wrong. It does not do inference. It
does not pick models, set context length, write prompts, or do RAG or chat. It
does not replace Ollama. The runner is an opaque child process that Hearth owns
and supervises; Hearth reads the runner's API and logs only to judge whether it
is healthy.

## Why this exists

If you run Ollama on a Mac you leave in a closet, three things quietly break the
"always available" promise. The runner process dies or, worse, wedges into a
state where it is still alive but no longer answering, so a plain "is it running"
check is fooled. The Mac goes to sleep and stops serving. And if you tried to fix
the first two with a launchd plist, you probably hit the `OLLAMA_HOST` env trap,
where the daemon does not inherit the environment you expected and ends up
listening on the wrong address, or only on localhost. Hearth exists to make a
local runner behave like a real, always on service on a machine nobody is sitting
at.

## Requirements

- macOS 14 or later.
- An existing Ollama install. Hearth supervises Ollama; it does not install it.
  By default it expects the binary at `/opt/homebrew/bin/ollama` (the Apple
  Silicon Homebrew location). If yours is elsewhere, for example
  `/usr/local/bin/ollama`, set `ollamaBinaryPath` in the config.
- No third party Swift dependencies. Hearth builds against Apple system
  frameworks only (Foundation, AppKit, IOKit, ServiceManagement, and
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

Hearth is meant to ship as a Developer ID signed and notarized build, not through
the Mac App Store. This is not a preference; the App Store requires the App
Sandbox, and the sandbox forbids a process from spawning and supervising another
process, which is the entire job. So the distribution path is Developer ID plus
notarization with the Hardened Runtime on and the App Sandbox off. The signing
and notarization steps are stubbed and commented at the bottom of
`scripts/package-app.sh`; fill in a signing identity and a notarytool profile to
enable them.

### Homebrew cask (planned)

A Homebrew cask is not published yet. When it is, install will be roughly
`brew install --cask hearth`. This section is a placeholder until that lands.

## Configure

Configuration is a JSON file at:

```
~/Library/Application Support/Hearth/config.json
```

On first launch, if the file is missing, Hearth writes a default template there
and uses it. Every key is optional; anything you leave out falls back to the
default below. A malformed file is reported in the menubar and the defaults are
used rather than refusing to start. To point Hearth at a config somewhere else,
set the `HEARTH_CONFIG` environment variable to that path.

Keys, defaults, and what they do:

- `ollamaBinaryPath` (default `"/opt/homebrew/bin/ollama"`): the Ollama binary
  Hearth launches and supervises.
- `host` (default `"127.0.0.1"`): the address the runner listens on, set via
  `OLLAMA_HOST` at spawn. Use `"0.0.0.0"` to listen on all interfaces (see the
  security note before you do).
- `port` (default `11434`): the listen port.
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
- `ntfyTopic` (default `null`): an ntfy topic to post notifications to, so a
  headless Mac can reach your phone. `null` disables ntfy.
- `ntfyServer` (default `"https://ntfy.sh"`): the ntfy server base URL. Point this
  at a self hosted server if you run one.
- `localNotifications` (default `true`): post to the local Notification Center
  when running as a bundled app.

A complete example:

```json
{
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
  "localNotifications": true
}
```

To get phone notifications, set `ntfyTopic` to a long, unguessable string and
subscribe to that same topic in the ntfy app on your phone. Anyone who knows a
public ntfy topic can read it, so treat the topic name like a secret.

## How it works

Hearth runs in managed mode. It spawns the `ollama serve` child itself and owns
it, setting the child's environment at launch. Because Hearth defines the child's
environment, `OLLAMA_HOST` is pinned to your configured host and port by
construction, which is what sidesteps the launchd env trap. Hearth does not
attach to an Ollama that something else started; it runs its own.

Health has two parts. Liveness asks whether the child process is still alive.
Readiness asks whether `GET /api/version` actually answers within the probe
timeout. Readiness is the important half: it catches the alive but wedged runner
that a liveness check alone would call healthy, and treats it as down.

When the runner stops serving, whether it crashed or wedged, Hearth restarts it
on an exponential backoff capped at `maxBackoffSeconds`. If failures keep coming,
specifically `crashLoopThreshold` failures within `crashLoopWindowSeconds`, Hearth
decides it is in a crash loop. It stops thrashing, enters a failing state, and
retries slowly on `failingProbeIntervalSeconds` instead of hammering the machine.
It keeps probing, so if the underlying problem clears, it recovers on its own and
returns to healthy.

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
resident (from `GET /api/ps`, surfaced for awareness only, never chosen by
Hearth), uptime of the current healthy streak, and the reason for the last
restart. The actions are Start, Stop, Restart, and Open Logs. The child's stdout
and stderr are captured to `~/Library/Logs/Hearth/ollama.log`.

## Architecture

The code is split into a logic half and a presentation half, with a hard line
between them.

`SupervisorCore` is a library that holds all the decision logic and imports no
AppKit and no SwiftUI. Time, process control, HTTP, power, and notifications all
sit behind protocols, so the whole thing is unit testable with fakes and never
touches real I/O in a test. The heart is an explicit restart state machine and a
pure exit classifier; both take the current time as an argument rather than
reading a clock, so their behavior is fully determined by their inputs.

`Hearth` is the executable: the menubar agent that wires the core to real
`Foundation.Process`, URLSession, IOKit, SMAppService, and UserNotifications, and
renders the published state.

## Testing

`SupervisorCore` is covered by a Swift Testing suite driven entirely by fakes for
the clock, process control, and HTTP. There is no real Ollama and no real
`sleep`; the fake clock is advanced by hand. The suite covers readiness catching
a hung but alive runner, exponential backoff timing, a crash loop entering the
failing state without thrashing, recovery back to healthy, and out of memory
versus crash classification from fixture stderr.

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

Continuous integration builds the package and runs this suite on every push and
pull request (see `.github/workflows/ci.yml`). Notarization and Homebrew
publishing are not wired into CI yet; they are stubbed in
`scripts/package-app.sh`.

### Trying it without Ollama

You can exercise the whole agent without installing Ollama, using a small stand
in runner that answers the two endpoints Hearth probes:

```
./scripts/smoke-test.sh
```

This builds Hearth, points it at `scripts/fake-runner.py` through a throwaway
config, and checks the acceptance behavior end to end: the agent starts and owns
the child, holds the power assertion (`pmset`), restarts the child when it is
killed externally, and releases the assertion and kills the child on a clean
shutdown. It launches the real menubar agent, so it needs a logged in desktop
session; it is a local helper, not a CI step.

## Known limitations

These are stated up front on purpose.

- The power assertion prevents idle sleep, which keeps a Mac that would otherwise
  sleep on idle (a desktop, or a plugged in laptop with the lid open) awake and
  serving. Keeping a laptop serving with the lid closed on battery is a separate,
  privileged concern and is not in this milestone.
- The phone gets notifications only. There is no remote control yet; you cannot
  restart or stop the runner from your phone in this milestone.
- A single runner, Ollama, is supported. The `Runner` protocol is built so LM
  Studio and mlx_lm can be added without touching the decision logic, but they
  are not implemented yet.
- Only managed mode. Hearth spawns and owns the runner. It does not attach to an
  Ollama that something else already started. If Hearth is killed abruptly
  without the chance to run its shutdown (for example a hard crash), the child it
  spawned can be left orphaned and may hold the port, which the next managed
  start would collide with. A clean quit, or a SIGTERM, shuts the child down.

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
up to you. Hearth sends only short status text to notifiers; no prompts, model
data, or runner content leave the machine.

## Roadmap

Near term intentions, roughly the current out of scope list:

- A thermal, tokens per second, and memory dashboard.
- A phone side control endpoint, so the phone can do more than receive alerts.
- Tailscale auto configuration.
- An authenticating reverse proxy in front of the runner.
- Additional runners behind the existing `Runner` protocol: LM Studio and
  mlx_lm.
- A pre login root LaunchDaemon, and attached mode for an externally managed
  runner.
- Notarization and Homebrew automation in CI.

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
