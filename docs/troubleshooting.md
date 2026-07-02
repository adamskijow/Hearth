<!-- SPDX-License-Identifier: MIT -->
# Troubleshooting

Run `hearth doctor` first; it catches most of these and tells you which. The menu
also shows a "config issues" line when it finds any.

- **The menubar flame never goes green / "runner binary not found."** Hearth is
  looking for the runner at the default path and not finding it. Set
  `ollamaBinaryPath` (or `lmStudioBinaryPath` / `mlxBinaryPath`) to the output of
  `which ollama`, in Preferences or the config. `hearth doctor` reports the path
  it tried.
- **LM Studio keeps restarting (down, restarting, down).** Managed mode does not
  work with LM Studio: `lms server start` exits immediately. Start LM Studio's
  server yourself, then run `hearth mode attached`; Hearth will watch it.
- **I use the official Ollama app.** The app already starts Ollama's server. Set
  `runner` to `ollama` and run `hearth mode attached` so Hearth watches that server
  instead of launching a second one. See [Ollama setup with Hearth](ollama.md).
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
  `brew services`. `hearth doctor` and the menu flag this; run `hearth mode
  attached` if brew should keep owning Ollama, or `brew services stop ollama` so
  Hearth is the sole supervisor. (Two Hearths can also collide; the single-instance
  guard handles that, but a non-Hearth manager needs stopping.) Note that
  `hearth mode` only edits the config: the running Hearth keeps fighting until you
  reload it (Reload Config in the menu, or `killall -HUP Hearth`).
- **The HTTP server answers but generations hang.** The shallow probe only proves
  the API answers. Set `probeModel` to a small model you have already pulled so
  Hearth periodically runs a one-token deep probe and catches inference-level
  wedges too.
- **The menu says "Crash loop" (or you got a "Runner failing" alert).** The runner
  failed several times in a row right after starting, so Hearth stopped restarting
  it rapidly and now retries slowly. Hearth has not given up: the moment the
  underlying problem clears, it recovers on its own. To find the problem, click
  **Open Logs** in the menu and read the last lines of `runner.log`: the usual
  causes are a model too large for the Mac's memory (the log ends in an
  out-of-memory error), another process holding the port (`hearth doctor` flags
  this), or a broken runner install after an upgrade. Fix the cause and Hearth
  brings it back; **Restart** in the menu retries immediately.
- **The status shows "spawn failed" / "No such file or directory" /
  "Permission denied."** Hearth tried to launch the runner and the launch itself
  failed, so the path in the config points at something missing or not executable.
  Run `hearth doctor` (it reports the path Hearth tried and the path it detected),
  then fix the binary path in Preferences (the Detect button finds the usual
  install locations).
- **The activity log says "stuck (still running, but not answering)."** The
  runner's process was alive but its API stopped answering in time: the hang
  (sometimes called a wedge) that Hearth exists to catch. Hearth restarts the
  runner when this happens; if it happens often, the
  [Ollama setup guide](ollama.md) covers deep probes, and a recurring hang after
  heavy load is usually the runner or GPU, not Hearth.
- **Phone alerts (ntfy) or webhooks stopped arriving.** Delivery failures are
  logged, one line per alert, to Hearth's stderr: `Hearth: ntfy alert to
  <server> failed: ...` (or `webhook alert to <host> failed`). For the menubar
  app that lands in Console.app (search "Hearth"); for the headless daemon it
  is in the launchd log path from its plist. A repeating line means a
  misconfigured endpoint (wrong server, 401, firewall), and it repeats on
  every alert until fixed, so a long-broken endpoint also makes that log
  noisy. Preferences has a "Send test notification" button to verify a fix.
