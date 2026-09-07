<!-- SPDX-License-Identifier: MIT -->
# FAQ

## Is Hearth affiliated with Ollama?

Hearth is an independent community project. Ollama and other runner vendors do
not develop or support it.

## Who is Hearth for?

Hearth serves people who rely on a local AI runner and want unattended recovery.
It watches Ollama, LM Studio, `mlx_lm`, or Osaurus, keeps the Mac awake, and sends
alerts. The runner still owns models and inference.

Full Hearth requires Apple silicon and macOS 14 or later.

## What failures can it recover?

Managed mode handles process exits and API hangs. An optional one-token probe can
detect inference hangs behind a responsive API. GPU or driver hangs that survive
a process restart can use the opt-in reboot ladder on a headless Mac.

See [How Hearth works](how-it-works.md) for the recovery path and
[Known limitations](limitations.md) for its boundaries.

## How do managed and attached modes differ?

- **Managed:** Hearth starts, stops, and restarts the runner.
- **Attached:** another app or service owns the runner; Hearth watches and alerts.

Use attached mode with Ollama.app and LM Studio. Use managed mode for a Homebrew
Ollama installation after stopping `brew services`. Managed `mlx_lm` also needs a
startup model. The Preferences labels are **Hearth starts runner** and **Watch
existing runner**.

## How do I know it works?

`hearth doctor` checks setup, and `hearth status` reports the supervisor's current
state. The default health check proves API responsiveness. Verify actual
generation with your workload and the optional inference check in Preferences.

In v1.5.1, repeated inference failures can leave the phase **Healthy** while
Hearth alerts that recovery was withheld. The next release adds a persistent
**Inference check failed** status and a separate `healthy` field. Neither a
shallow success nor the lifecycle phase proves recent inference. See
[known limitations](limitations.md).

For an isolated recovery demonstration, use `make demo`. It supplies its own fake
runner, configuration, and data directory.

## What happens during a crash loop?

Hearth backs off after repeated failures, reports **Crash loop**, and keeps
probing. It retries slowly until the underlying problem clears. Open **Logs** or
run `hearth logs -n 100` to find the cause.

## Must my apps change?

Apps continue using the runner's normal address. A short retry handles the
restart window for requests safe to retry. Automatic inference recovery requires
client traffic through the optional metrics proxy, which changes the client
endpoint. Apps that need startup ordering can use:

```sh
hearth wait-ready && start-my-app
```

See [Integrating with Hearth](integrating.md).

## What leaves the Mac?

Hearth sends health checks to the configured runner and, when enabled, relays
client traffic through its metrics proxy. A remote runner receives that traffic.
Configured ntfy or webhook alerts receive short status messages. The optional `alertsIncludeLogTail` setting
also sends a bounded runner-log excerpt, which may contain paths, model names, or
request fragments. `hearth doctor` warns when that setting uses public ntfy.sh.

See the [privacy policy](../PRIVACY.md).

## Do I need ntfy, Tailscale, or remote control?

They are optional. ntfy pushes phone alerts. Tailscale provides private remote
access. The control endpoint serves authenticated status and runner controls.

## Can one Mac supervise several runners?

Run one Hearth instance per runner, each with a separate config, data directory,
runner port, and any enabled control and metrics-proxy ports:

```sh
HEARTH_CONFIG="$HOME/.config/hearth-mlx.json" \
HEARTH_DATA_DIR="$HOME/Library/Application Support/Hearth-MLX" \
hearth --headless
```

The single-instance lock is scoped to the config file. `HEARTH_DATA_DIR` also
isolates process-recovery records and logs; separate configs alone still share
the default runtime data. Configure additional instances explicitly rather than
installing multiple copies of the canonical login agent.

## Can I pause alerts?

**Pause Notifications** silences local, ntfy, and webhook delivery while health
checks and event logging continue.

## Does Hearth work before login?

`hearth install-agent` starts headless supervision after login. A root
LaunchDaemon can start before login; follow [Running headless](running-headless.md).

## How do I uninstall it?

```sh
brew uninstall --cask hearth
```

Add `--zap` to remove Hearth's config and logs. Run `hearth uninstall-agent`
first if you installed the login agent. Runner applications and models remain.
