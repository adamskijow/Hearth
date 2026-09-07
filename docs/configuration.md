<!-- SPDX-License-Identifier: MIT -->
# Configuration reference

Hearth reads `~/Library/Application Support/Hearth/config.json`. Override the
path with `HEARTH_CONFIG`. Omitted keys use the defaults below; the resulting
configuration must still satisfy runner-specific requirements, such as `mlxModel`
for managed MLX. Malformed JSON and error-level diagnostics block activation.
Edit through Preferences or JSON, then choose **Reload Config** or send `SIGHUP`.
Notification, pressure, heartbeat, and control settings reload live. Runner and
engine changes restart supervision. The root daemon reloads through launchd and
briefly cycles a managed runner.

Run `hearth doctor` after editing, or `sudo hearth doctor-daemon` for
`/etc/hearth/config.json`. Errors block activation; warnings are advisory.

Switch modes with:

```sh
hearth mode managed
hearth mode attached
```

Add `--daemon` with `sudo` for the root config. Attached mode requires a serving
compatible runner unless `--force` is supplied.

Reload the app after `hearth mode` with **Reload Config** or `killall -HUP Hearth`.
Restart the root daemon with `sudo launchctl kickstart -k
system/com.hearth.daemon`.

## Runner

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `runner` | string | `"ollama"` | Which runner to supervise: `ollama`, `lmstudio`, `mlx`, or `osaurus`. |
| `mode` | string | `"managed"` | `managed` (Hearth launches and owns the runner) or `attached` (Hearth only watches a runner you start yourself). |
| `ollamaBinaryPath` | string | `"/opt/homebrew/bin/ollama"` | Path to the `ollama` binary (managed Ollama). |
| `lmStudioBinaryPath` | string | `"/usr/local/bin/lms"` | Path to the `lms` CLI. LM Studio uses attached mode. |
| `mlxBinaryPath` | string | `"/opt/homebrew/bin/mlx_lm.server"` | Path to `mlx_lm.server` (managed mlx_lm). |
| `mlxModel` | string or null | `null` | Hugging Face repository ID or local model directory passed to `mlx_lm.server --model`. Required for managed mlx_lm; unused in attached mode. |
| `osaurusBinaryPath` | string | `"/Applications/Osaurus.app/Contents/MacOS/osaurus"` | Path to the `osaurus` CLI. Attached mode is recommended; Osaurus usually serves on port 1337. |
| `host` | string | `"127.0.0.1"` | Address the runner binds to. `127.0.0.1` keeps it on this machine; `0.0.0.0` opens it to your LAN so another computer can reach it (`hearth doctor` reports the URL and the firewall caveat). |
| `port` | int | `11434` | Port the runner serves on (Ollama's default is 11434). |
| `runnerEnv` | object | `{}` | Environment variables for a managed runner. Hearth derives `OLLAMA_HOST` from `host` and `port`; a conflicting value here is ignored and reported by `hearth doctor`. |

### Managed mlx_lm

Current `mlx_lm.server` releases require a model when the server starts. Set a
Hugging Face repository ID or an existing local model directory; Hearth passes
the value as one argument, so local paths containing spaces are supported:

```json
{
  "runner": "mlx",
  "mode": "managed",
  "mlxModel": "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
  "host": "127.0.0.1",
  "port": 8080
}
```

Managed mlx_lm requires a nonblank `mlxModel`. Attached mode accepts a server
started elsewhere without this setting.

Keep mlx_lm on loopback unless an authenticated private proxy protects it. The
[official server documentation](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md)
says the server implements only basic security checks; `hearth doctor` warns for
every non-loopback MLX bind.

### Common Ollama setups

For Homebrew Ollama, use managed mode and stop `brew services` so Hearth is the
only supervisor:

```json
{
  "runner": "ollama",
  "mode": "managed",
  "host": "127.0.0.1",
  "port": 11434
}
```

For the official Ollama app, use attached mode. The app owns the server; Hearth
only watches it:

```json
{
  "runner": "ollama",
  "mode": "attached",
  "host": "127.0.0.1",
  "port": 11434
}
```

See [ollama.md](ollama.md) for the full Ollama setup guide, including deep probes.

## Health and restart policy

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `probeTimeoutSeconds` | number | `2` | How long a readiness probe waits before it counts as a failure. |
| `probeIntervalSeconds` | number | `5` | How often to probe while healthy. |
| `busyTimeoutSeconds` | number | `600` | Busy (503) duration before Hearth treats the state as a hang. Minimum 30. |
| `startupGraceSeconds` | number | `30` | How long to allow for the runner to come up before treating it as failed. |
| `startupProbeIntervalSeconds` | number | `1` | Probe cadence during startup and restart. |
| `initialBackoffSeconds` | number | `1` | Wait before the first restart attempt. Minimum 0.1. |
| `backoffMultiplier` | number | `2` | Each failed restart multiplies the wait by this (clamped to at least 1). |
| `maxBackoffSeconds` | number | `60` | Upper limit on the restart wait (floored at the initial backoff, so backoff can always grow). |
| `crashLoopThreshold` | int | `5` | Failures within the window that trip the crash-loop brake (clamped to at least 1). |
| `crashLoopWindowSeconds` | number | `60` | Sliding window for counting failures toward the brake. |
| `failingProbeIntervalSeconds` | number | `30` | Slow, steady retry cadence once in the crash-loop (failing) state. |
| `maintenanceRestartHours` | number | `0` | Hours between healthy maintenance restarts. `0` disables; minimum enabled value 1. |
| `maintenanceWindow` | string or null | `null` | Optional daily window (`"HH:MM-HH:MM"`, 24-hour local time) during which scheduled maintenance restarts may fire; a due restart waits for the window to open. Spans midnight when the end is before the start (`"23:00-06:00"`). Null means any time. |
| `warmModelsAfterRestart` | bool | `false` | Reload previously resident models after recovery. Failures trigger a "Models not restored" alert. |
| `restartOnBinaryChange` | bool | `false` | Restart a managed runner when its binary changes on disk (an upgrade), so it adopts the new version instead of serving the old one. Catches a Homebrew Cellar relink. `hearth update` pairs with this: it runs `brew upgrade ollama` and makes sure a running Hearth adopts the result; when Hearth itself came from the Homebrew cask it also runs `brew upgrade --cask hearth` and says how to relaunch onto the new build. |
| `runnerMemoryLimitMB` | int | `0` | Restart a healthy managed runner above this RSS limit. `0` disables. Leave room for loaded models. |
| `probeModel` | string or null | `null` | Model for the optional one-token inference probe. Scheduled checks run while resident. Automatic deep recovery also requires client traffic through the metrics proxy. |
| `deepProbeIntervalSeconds` | number | `60` | How often to run the deep probe, separate from and slower than the shallow probe. Floored at 5. |
| `deepProbeTimeoutSeconds` | number | `30` | Resident inference-probe timeout. Setup and Check Now allow at least 60 seconds for uncertain loads. Minimum 1. |
| `modelOOMThreshold` | int | `2` | After a model is resident at this many memory-related crashes (an out-of-memory kill, or a crash as it loads) within `modelOOMWindowSeconds`, Hearth flags it as likely too large for this Mac: a "Model likely too large" alert, an `oversizedModels` entry on `/status`, and a menu warning, so you switch models instead of crash-looping. `0` disables the check. |
| `modelOOMWindowSeconds` | number | `1800` | Sliding window, in seconds, for counting a model's memory-related crashes toward `modelOOMThreshold`. A model un-flags once its crashes age out of this window. |

## Notifications

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `localNotifications` | bool | `true` | Show a macOS notification on down/recovered (needs a logged-in session and a signed app). |
| `ntfyTopic` | string or null | `null` | ntfy topic for phone alerts. Special characters are percent-encoded. Delivery failures go to stderr. |
| `ntfyServer` | string | `"https://ntfy.sh"` | ntfy server URL. |
| `webhookURL` | string or null | `null` | POST `level`, `title`, `body`, `event`, and `timestamp` for each notification. Delivery failures go to stderr. |
| `memoryAlertPercent` | int | `90` | Alert when system memory used reaches this percent (the precursor to the runner being killed under pressure). `0` disables the memory alert. |
| `thermalAlerts` | bool | `true` | Alert when the Mac's thermal state goes serious or critical. |
| `notificationsPaused` | bool | `false` | Silence local, ntfy, and webhook delivery while event logging continues. |
| `alertsIncludeLogTail` | bool | `false` | Append up to five sanitized runner-log lines to failure alerts. These may contain paths, model names, or request fragments. Managed mode only; prefer private notification services. |
| `heartbeatURL` | string or null | `null` | GET this dead-man's-switch URL while healthy. Supports Uptime Kuma and healthchecks.io. |
| `heartbeatIntervalSeconds` | number | `60` | How often to send the heartbeat while healthy. Floored at 10. |

## Metrics proxy (traffic visibility and tokens per second)

The optional proxy supplies traffic visibility for inference recovery and
routine restart draining. Point clients at `metricsProxyPort` instead of the
runner port. It currently counts open TCP connections; this is not a complete
measure of active requests or proof that all clients use the proxy. See
[known limitations](limitations.md) and the [product plan](product-plan.md).

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `metricsProxyEnabled` | bool | `false` | Relay runner traffic and read runner-reported token timing for `/metrics`. Direct runner traffic is absent from these metrics. |
| `metricsProxyPort` | int | `11436` | Port the proxy listens on, on the same host as the runner. Must differ from the runner and control ports. |
| `drainSeconds` | number | `0` | Maximum wait for proxied in-flight work before a routine restart. `0` restarts immediately; failure recovery skips draining. |

## Control endpoint (phone-side remote control)

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `controlEnabled` | bool | `false` | Serve a small HTTP API so a phone can check status and start/stop/restart. |
| `controlHost` | string | `"127.0.0.1"` | Private bind address. `"tailscale"` resolves the current tailnet IPv4 and falls back to loopback. |
| `controlPort` | int | `11435` | Control endpoint port. Must differ from `port`. |
| `controlToken` | string or null | `null` | Required bearer token on every control request. The endpoint refuses to start without one. Audits as `default`. |
| `controlTokens` | object | `{}` | Named full-control tokens. Process actions log the token name. Use long unique secrets. |
| `controlStatusTokens` | object | `{}` | Named read-only tokens for `/status` and `/metrics`. Process commands return HTTP 403. Use secrets distinct from control tokens. |

See [reverse-proxy.md](reverse-proxy.md) for exposing the runner or the control
endpoint with TLS.

## Runner log rotation

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `logMaxBytes` | int | `5000000` | Rotate `runner.log` once it grows past this many bytes. `0` disables rotation. |
| `logKeepFiles` | int | `3` | How many rotated log files to keep before deleting the oldest. |

## Reboot escalation

Reboot escalation handles driver or GPU hangs that survive a process restart. It
is disabled by default and requires the root daemon or the experimental
privileged helper. See
[Recovering a wedge a restart cannot](running-headless.md#recovering-a-wedge-a-restart-cannot)
for the full safety story.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `rebootOnWedge` | bool | `false` | Enable the reboot rung. When off, Hearth never reboots. |
| `rebootEscalateAfterSeconds` | number | `600` | How long the runner must stay failing (process restarts not helping) before a reboot is considered. Clamped to at least 60. |
| `rebootMinIntervalSeconds` | number | `1800` | Minimum time between recovery reboots. A reboot sooner than this that did not help means Hearth stops and notifies instead of looping. Clamped to at least 300. |
| `rebootMaxPerDay` | int | `3` | Most recovery reboots allowed in a rolling 24 hours. Clamped to at least 1. |
| `rebootOnlyOnProcessFailure` | bool | `false` | Require a process exit in the failing streak before reboot. Pure API hangs then alert without rebooting. |
| `rebootViaHelper` | bool | `false` | EXPERIMENTAL: send the recovery reboot through the `hearth-reboot-helper` root daemon instead of rebooting directly, so the headless supervisor itself need not run as root. Needs the helper installed (`sudo ./scripts/install-reboot-helper.sh`); see [Running headless](running-headless.md). |
| `rebootHelperSocket` | string | `"/var/run/hearth-reboot.sock"` | The helper's unix socket path. |

## Runner privilege drop (root daemon)

The root LaunchDaemon keeps Hearth privileged and launches managed runners under
the unprivileged `runnerUser`. Missing, unknown, or root accounts block managed
spawn.

Hearth supplies the account's `HOME`, `USER`, and `LOGNAME` to the dropped runner
automatically (a LaunchDaemon has no `HOME`, and Ollama refuses to start without
one). If your models live outside that account's `~/.ollama`, set `OLLAMA_MODELS` in
`runnerEnv` to point at them; anything you set in `runnerEnv` always wins.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `runnerUser` | string | unset | Unprivileged account for managed root-daemon runners. Missing, unknown, or root values block spawn. Ignored by the user app. |

Apple silicon validation confirmed Metal offload after privilege drop. Check the
runner log for `Metal` or `offloaded N/N layers to GPU`; use attached mode or a
different unprivileged account if offload fails.

## Example

A minimal managed-Ollama config with phone control over Tailscale:

```json
{
  "runner": "ollama",
  "mode": "managed",
  "host": "127.0.0.1",
  "port": 11434,
  "ntfyTopic": "my-private-hearth-topic",
  "controlEnabled": true,
  "controlHost": "100.x.y.z",
  "controlPort": 11435,
  "controlToken": "a-long-random-secret"
}
```

Add `runnerUser` when this config belongs to the root daemon.
