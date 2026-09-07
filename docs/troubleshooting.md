<!-- SPDX-License-Identifier: MIT -->
# Troubleshooting

Run `hearth doctor` first. It checks configuration, binary paths, ports,
permissions, and competing process managers.

## Startup and ownership

- **Runner binary missing:** set the runner's binary path in Preferences. The
  **Detect** button and `hearth doctor` show common locations.
- **LM Studio keeps restarting:** start its server in LM Studio, then run `hearth
  mode attached` and reload Hearth.
- **Ollama.app is running:** use attached mode so Ollama.app retains ownership.
- **Managed `mlx_lm` reports `mlxModel`:** enter a Hugging Face repository ID or
  local model directory under **Startup model**. First use may download the model.
- **Managed state keeps cycling:** stop the competing manager, often `brew
  services`, or switch Hearth to attached mode. Reload after `hearth mode` changes.
- **Spawn failed or permission denied:** correct the configured binary path and
  executable permissions.

## Health and recovery

- **HTTP works but generation hangs:** configure `probeModel`. Enable the metrics
  proxy and route clients through it for automatic deep-probe recovery.
- **Crash loop:** inspect **Open Logs** or `hearth logs -n 100`. Common causes are
  a busy port, broken runner install, or model memory pressure.
- **Stuck (still running, but not answering):** the process survived while its API
  timed out. Hearth restarts managed runners after confirmation.
- **A large model repeatedly crashes:** choose a smaller quantization or context.
  `oversizedModels` and the **Model likely too large** alert identify repeated
  memory-related failures. Tune `modelOOMThreshold`, `modelOOMWindowSeconds`, or
  `runnerMemoryLimitMB` if needed.
- **A stray managed runner remains:** relaunch Hearth so it can sweep the recorded
  process group. Deleting `runner-state.json` removes that recovery record.

## Network and remote access

- **Another computer cannot connect:** set `host` to a trusted LAN address or
  `0.0.0.0`, allow the runner port through the firewall, and use the URL from
  `hearth doctor`. Prefer Tailscale for access beyond the LAN.
- **Control endpoint unreachable:** enable `controlEnabled`, set a token, and
  verify `controlHost` and `controlPort`. Bind it to localhost or a private
  interface.
- **ntfy or webhook alerts fail:** search Console for `Hearth: ntfy alert` or
  `Hearth: webhook alert`. Preferences includes **Send test notification**.

## macOS integration

- **Login item or notifications fail in a source run:** install the packaged app
  with `make install` or Homebrew. macOS services require an app bundle and
  signature.
- **No local notification in headless mode:** use ntfy, a webhook, or heartbeat;
  Notification Center needs a logged-in desktop session.

Configuration details are in the [reference](configuration.md). Ollama ownership
examples are in the [Ollama guide](ollama.md).
