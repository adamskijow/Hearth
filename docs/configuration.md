<!-- SPDX-License-Identifier: MIT -->
# Configuration reference

Hearth reads a single JSON file. The default location is
`~/Library/Application Support/Hearth/config.json`; set `HEARTH_CONFIG` to point
at another file (handy for a throwaway config). Decoding is lenient: every key is
optional and missing keys fall back to the defaults below, so a partial or empty
`{}` still works. Edit it from the Preferences window or by hand; either way, Save
or `hearth` with `SIGHUP` (or the menu's Reload Config) applies it without a
restart.

Run `hearth doctor` after editing to catch problems (bad ports, an unknown runner
or mode, a control endpoint with no token, timings that cannot grow). For the root
daemon config at `/etc/hearth/config.json`, run `sudo hearth doctor-daemon`.

## Runner

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `runner` | string | `"ollama"` | Which runner to supervise: `ollama`, `lmstudio`, or `mlx`. |
| `mode` | string | `"managed"` | `managed` (Hearth launches and owns the runner) or `attached` (Hearth only watches a runner you start yourself). |
| `ollamaBinaryPath` | string | `"/opt/homebrew/bin/ollama"` | Path to the `ollama` binary (managed Ollama). |
| `lmStudioBinaryPath` | string | `"/usr/local/bin/lms"` | Path to the `lms` CLI (managed LM Studio). |
| `mlxBinaryPath` | string | `"/opt/homebrew/bin/mlx_lm.server"` | Path to `mlx_lm.server` (managed mlx_lm). |
| `host` | string | `"127.0.0.1"` | Address the runner binds to. `127.0.0.1` keeps it on this machine; `0.0.0.0` opens it to your LAN so another computer can reach it (`hearth doctor` reports the URL and the firewall caveat). |
| `port` | int | `11434` | Port the runner serves on (Ollama's default is 11434). |
| `runnerEnv` | object | `{}` | Extra environment variables for a managed runner, so a hand-tuned setup is a config key rather than a launchd plist edit. Example: `{"OLLAMA_LOAD_TIMEOUT": "10m", "OLLAMA_KEEP_ALIVE": "30m"}`. Merged into the child's environment at spawn. Hearth derives `OLLAMA_HOST` from `host`/`port`, so a value for it here is ignored (and `hearth doctor` warns). |

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
| `startupGraceSeconds` | number | `30` | How long to allow for the runner to come up before treating it as failed. |
| `startupProbeIntervalSeconds` | number | `1` | Probe cadence during startup and restart. |
| `initialBackoffSeconds` | number | `1` | Wait before the first restart attempt. |
| `backoffMultiplier` | number | `2` | Each failed restart multiplies the wait by this (clamped to at least 1). |
| `maxBackoffSeconds` | number | `60` | Upper limit on the restart wait. |
| `crashLoopThreshold` | int | `5` | Failures within the window that trip the crash-loop brake (clamped to at least 1). |
| `crashLoopWindowSeconds` | number | `60` | Sliding window for counting failures toward the brake. |
| `failingProbeIntervalSeconds` | number | `30` | Slow, steady retry cadence once in the crash-loop (failing) state. |
| `maintenanceRestartHours` | number | `0` | Proactively cycle a healthy runner this often (in hours) to clear the memory creep that degrades a 24/7 runner. `0` disables it; an enabled value is floored at 1 hour. A common value is `24`. |
| `restartOnBinaryChange` | bool | `false` | Restart a managed runner when its binary changes on disk (an upgrade), so it adopts the new version instead of serving the old one. Catches a Homebrew Cellar relink. |
| `probeModel` | string or null | `null` | Optional deep readiness probe. The default `/api/version` probe only proves the HTTP server answers; it misses a wedged model runner that still responds there (a GPU or model-load hang). Set a model name and Hearth periodically runs a one-token generation against it, so an inference-level wedge is caught and restarted. Off by default; it names a model and does GPU work. It sends no `keep_alive`, so the model's residency follows the runner's own policy (your `OLLAMA_KEEP_ALIVE`), not one the probe imposes. |
| `deepProbeIntervalSeconds` | number | `60` | How often to run the deep probe, separate from and slower than the shallow probe. Floored at 5. |
| `deepProbeTimeoutSeconds` | number | `30` | How long the deep probe may take before it counts as wedged. Generous, because a cold model load is legitimately slow. Floored at 1. |

## Notifications

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `localNotifications` | bool | `true` | Show a macOS notification on down/recovered (needs a logged-in session and a signed app). |
| `ntfyTopic` | string or null | `null` | Subscribe to this topic in the [ntfy](https://ntfy.sh) app for phone alerts. Null disables ntfy. |
| `ntfyServer` | string | `"https://ntfy.sh"` | ntfy server URL. |
| `webhookURL` | string or null | `null` | POST a small JSON status body (`level`, `title`, `body`, `event`, `timestamp`) to this URL on each notification, to wire Hearth into your own automation. Null disables it. Only Hearth's own status is sent, never runner content. |
| `memoryAlertPercent` | int | `90` | Alert when system memory used reaches this percent (the precursor to the runner being killed under pressure). `0` disables the memory alert. |
| `thermalAlerts` | bool | `true` | Alert when the Mac's thermal state goes serious or critical. |

## Control endpoint (phone-side remote control)

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `controlEnabled` | bool | `false` | Serve a small HTTP API so a phone can check status and start/stop/restart. |
| `controlHost` | string | `"127.0.0.1"` | Address the control endpoint binds to. Use a private or Tailscale address, never `0.0.0.0` on the open internet. |
| `controlPort` | int | `11435` | Control endpoint port. Must differ from `port`. |
| `controlToken` | string or null | `null` | Required bearer token on every control request. The endpoint refuses to start without one. |

See [reverse-proxy.md](reverse-proxy.md) for exposing the runner or the control
endpoint with TLS.

## Runner log rotation

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `logMaxBytes` | int | `5000000` | Rotate `runner.log` once it grows past this many bytes. `0` disables rotation. |
| `logKeepFiles` | int | `3` | How many rotated log files to keep before deleting the oldest. |

## Reboot escalation

The last rung of the recovery ladder, for a wedge a process restart cannot clear
(a driver/GPU-level hang). Off by default, and effective only when Hearth runs as
root (the headless LaunchDaemon), since rebooting needs privileges. See
[Recovering a wedge a restart cannot](running-headless.md#recovering-a-wedge-a-restart-cannot)
for the full safety story.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `rebootOnWedge` | bool | `false` | Enable the reboot rung. When off, Hearth never reboots. |
| `rebootEscalateAfterSeconds` | number | `600` | How long the runner must stay failing (process restarts not helping) before a reboot is considered. Clamped to at least 60. |
| `rebootMinIntervalSeconds` | number | `1800` | Minimum time between recovery reboots. A reboot sooner than this that did not help means Hearth stops and notifies instead of looping. Clamped to at least 300. |
| `rebootMaxPerDay` | int | `3` | Most recovery reboots allowed in a rolling 24 hours. Clamped to at least 1. |
| `rebootOnlyOnProcessFailure` | bool | `false` | Reboot only when the failing streak included a real process exit (a crash), never for a pure "alive but not answering" wedge. Turn this on if you do not fully trust the runner: it stops a runner that only controls its HTTP responses from driving a reboot, at the cost that a genuine wedge is escalated to a notification instead of auto-recovered. |

## Runner privilege drop (root daemon)

When Hearth runs as the root LaunchDaemon, Hearth itself stays root so it can be
kept alive by launchd and perform optional reboot recovery. The managed runner is
different: it must run as a lower-privileged account. `runnerUser` names that
account. If Hearth is root and `runnerUser` is unset, unresolved, or resolves to
root, managed runner spawn fails closed rather than running the LLM runner as root.

Hearth supplies the account's `HOME`, `USER`, and `LOGNAME` to the dropped runner
automatically (a LaunchDaemon has no `HOME`, and Ollama refuses to start without
one). If your models live outside that account's `~/.ollama`, set `OLLAMA_MODELS` in
`runnerEnv` to point at them; anything you set in `runnerEnv` always wins.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `runnerUser` | string | unset | Account name to run the spawned runner as, when Hearth is root. Required for managed root-daemon mode. Ignored for the non-root menubar app (it logs a note and runs normally). If the account does not resolve, or resolves to root, Hearth refuses to start the managed runner rather than run it as root (fail closed). |

GPU access holds from the daemon session: verified end to end on Apple Silicon, a
root daemon that drops the runner to a regular user still reaches Metal and offloads
the model to the GPU. It is still worth a check on your own setup (watch the runner's
log for the `Metal` / `offloaded N/N layers to GPU` lines); if a given account cannot
reach the GPU, use attached mode or choose another unprivileged account rather than
leaving the runner to inherit root.

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
  "controlToken": "a-long-random-secret",
  "runnerUser": "your-mac-user"
}
```
